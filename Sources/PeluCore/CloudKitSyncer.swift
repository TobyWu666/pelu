import CloudKit
import Foundation

/// All Pelu's CloudKit operations live here. Mac uses `save(_:)`; iOS uses
/// `fetchAllMacs()` and the subscription helpers.
///
/// Container: `iCloud.org.tobywu.pelu` (private database, single zone).
/// Records are `MacSnapshot` keyed by `mac-{macId}` for stable per-Mac updates.
public actor CloudKitSyncer {
    public enum SyncError: Error {
        case accountUnavailable
        case recordEncodeFailed(Error)
        case ckError(CKError)
        case unknown(Error)
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let bundleVersion: String

    public init(
        containerIdentifier: String = MacSnapshotRecord.containerIdentifier,
        bundleVersion: String
    ) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.bundleVersion = bundleVersion
    }

    // MARK: - Mac side: save snapshot

    /// Upsert this Mac's snapshot. We first try to fetch the existing record so
    /// we can carry its `recordChangeTag` (CKRecord optimistic locking). If
    /// another writer wins between our fetch and save, fetch its new change tag
    /// and retry once with this newest local snapshot.
    public func save(_ mac: MacSnapshot) async throws {
        do {
            try await saveAttempt(mac)
        } catch let ckError as CKError where Self.isRecordConflict(ckError) {
            do {
                try await saveAttempt(mac)
            } catch {
                throw Self.wrap(error)
            }
        } catch {
            throw Self.wrap(error)
        }
    }

    private func saveAttempt(_ mac: MacSnapshot) async throws {
        let recordID = MacSnapshotRecord.recordID(forMacId: mac.macId)

        let existing: CKRecord?
        do {
            existing = try await database.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            existing = nil // first upload for this Mac
        }

        let record: CKRecord
        do {
            record = try MacSnapshotRecord.makeRecord(
                from: mac,
                bundleVersion: bundleVersion,
                existing: existing
            )
        } catch {
            throw SyncError.recordEncodeFailed(error)
        }

        _ = try await database.save(record)
    }

    private static func isRecordConflict(_ error: CKError) -> Bool {
        if error.code == .serverRecordChanged { return true }
        guard error.code == .partialFailure else { return false }
        return error.partialErrorsByItemID?.values.contains {
            ($0 as? CKError)?.code == .serverRecordChanged
        } ?? false
    }

    private static func wrap(_ error: Error) -> SyncError {
        if let syncError = error as? SyncError { return syncError }
        if let ckError = error as? CKError { return .ckError(ckError) }
        return .unknown(error)
    }

    // MARK: - iOS side: fetch aggregate

    /// Fetch every `MacSnapshot` record in the user's private DB. Returns them
    /// already wrapped in `AggregateSnapshot`, sorted alphabetically by label so
    /// the "primary" Mac (used by Widget / Live Activity) is stable.
    ///
    /// We deliberately don't pass a `sortDescriptors` to CKQuery: that would
    /// require the `label` field be marked **Sortable** in CloudKit Dashboard
    /// (which new auto-generated schemas are not). Sorting client-side avoids
    /// that gotcha entirely.
    public func fetchAllMacs() async throws -> AggregateSnapshot {
        let query = CKQuery(
            recordType: MacSnapshotRecord.recordType,
            predicate: NSPredicate(value: true)
        )

        var collected: [MacSnapshot] = []
        do {
            var (matchResults, cursor) = try await database.records(matching: query)
            while true {
                for (_, result) in matchResults {
                    switch result {
                    case .success(let record):
                        if let mac = try? MacSnapshotRecord.decode(record) {
                            collected.append(mac)
                        }
                    case .failure:
                        // Skip individual broken records; don't fail the whole fetch.
                        continue
                    }
                }

                guard let nextCursor = cursor else { break }
                (matchResults, cursor) = try await database.records(continuingMatchFrom: nextCursor)
            }
        } catch let ckError as CKError {
            throw SyncError.ckError(ckError)
        } catch {
            throw SyncError.unknown(error)
        }

        collected.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return AggregateSnapshot(macs: collected)
    }

    // MARK: - iOS side: device management

    /// Delete this Mac's record from CloudKit. Used by the iOS Settings
    /// device list so the user can retire Macs they no longer want syncing.
    /// If the same Mac later writes a fresh snapshot, the record will simply
    /// be re-created on next save — the deletion is not "permanent" in any
    /// stronger sense than that.
    public func deleteMac(macId: String) async throws {
        let recordID = MacSnapshotRecord.recordID(forMacId: macId)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            // Already gone — treat as success.
            return
        } catch let ckError as CKError {
            throw SyncError.ckError(ckError)
        } catch {
            throw SyncError.unknown(error)
        }
    }

    // MARK: - iOS side: subscription

    /// Subscribe to every record change so CloudKit fires a silent APNs push to
    /// wake the app. Idempotent — re-subscribing with the same ID just updates.
    /// Call this once on app launch from iOS.
    public func ensureSubscriptionRegistered() async throws {
        let subscriptionID = "pelu-mac-snapshot-changes-v1"

        // Check first — saving an identical subscription throws .serverRejectedRequest.
        if let _ = try? await database.subscription(for: subscriptionID) {
            return
        }

        let subscription = CKQuerySubscription(
            recordType: MacSnapshotRecord.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true // silent push
        info.alertBody = nil
        info.shouldBadge = false
        info.soundName = nil
        subscription.notificationInfo = info

        do {
            _ = try await database.save(subscription)
        } catch let ckError as CKError where ckError.code == .serverRejectedRequest {
            // Already exists with slightly different config; ignore.
            return
        } catch let ckError as CKError {
            throw SyncError.ckError(ckError)
        } catch {
            throw SyncError.unknown(error)
        }
    }
}
