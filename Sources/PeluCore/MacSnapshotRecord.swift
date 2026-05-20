import CloudKit
import Foundation

/// Translates between our domain model (`MacSnapshot`) and CloudKit's `CKRecord`.
///
/// Schema policy (see pelu-plan.md §5):
/// - Fields are **only added, never removed** — old readers ignore unknown fields.
/// - `schemaVersion` lets us route to the correct decoder when format changes.
/// - `payload` carries the `[UsageMetric]` array as JSON `Data`, so internal model
///   evolution is handled by Codable + `decodeIfPresent` rather than CKRecord schema
///   changes (which are nearly irreversible once deployed).
public enum MacSnapshotRecord {
    /// CloudKit record type. Stable string — changing this invalidates all existing records.
    public static let recordType = "MacSnapshot"

    /// Container identifier — must match Apple Developer portal config.
    public static let containerIdentifier = "iCloud.org.tobywu.pelu"

    /// Current writer-side schema version. Bump when you change how fields are laid out.
    /// Older readers will see this number and either degrade gracefully or skip the record.
    public static let currentSchemaVersion: Int64 = 1

    enum Field: String {
        case macId
        case label
        case schemaVersion
        case bundleVersion
        case generatedAt
        case payload
    }

    public enum DecodeError: Error {
        case missingField(String)
        case payloadDecodeFailed(underlying: Error)
        case unsupportedSchemaVersion(Int64)
    }

    /// `recordName` derived from macId. Stable per-Mac so updates land on the same record
    /// instead of creating duplicates.
    public static func recordID(forMacId macId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "mac-\(macId)")
    }

    /// Build a CKRecord for upload. If `existing` is provided (from a prior fetch), we
    /// preserve its `recordChangeTag` so CloudKit's optimistic locking can detect races.
    public static func makeRecord(
        from mac: MacSnapshot,
        bundleVersion: String,
        existing: CKRecord? = nil
    ) throws -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: recordType,
            recordID: recordID(forMacId: mac.macId)
        )

        record[Field.macId.rawValue] = mac.macId as NSString
        record[Field.label.rawValue] = mac.label as NSString
        record[Field.schemaVersion.rawValue] = NSNumber(value: currentSchemaVersion)
        record[Field.bundleVersion.rawValue] = bundleVersion as NSString
        record[Field.generatedAt.rawValue] = mac.snapshot.generatedAt as NSDate

        let payload = try JSONEncoder.peluAPI.encode(mac.snapshot.metrics)
        record[Field.payload.rawValue] = payload as NSData

        return record
    }

    /// Decode a CKRecord into a MacSnapshot. Tolerant of missing optional fields,
    /// strict on the required ones.
    public static func decode(_ record: CKRecord) throws -> MacSnapshot {
        guard let macId = record[Field.macId.rawValue] as? String, !macId.isEmpty else {
            throw DecodeError.missingField(Field.macId.rawValue)
        }
        guard let label = record[Field.label.rawValue] as? String, !label.isEmpty else {
            throw DecodeError.missingField(Field.label.rawValue)
        }
        guard let generatedAt = record[Field.generatedAt.rawValue] as? Date else {
            throw DecodeError.missingField(Field.generatedAt.rawValue)
        }
        guard let payload = record[Field.payload.rawValue] as? Data else {
            throw DecodeError.missingField(Field.payload.rawValue)
        }

        // schemaVersion presence is graceful — old records may not have it.
        let writtenVersion = (record[Field.schemaVersion.rawValue] as? Int64) ?? 1
        if writtenVersion > currentSchemaVersion + 1 {
            // Reader is older than the writer by 2+ versions — refuse to interpret.
            throw DecodeError.unsupportedSchemaVersion(writtenVersion)
        }

        let metrics: [UsageMetric]
        do {
            metrics = try JSONDecoder.peluAPI.decode([UsageMetric].self, from: payload)
        } catch {
            throw DecodeError.payloadDecodeFailed(underlying: error)
        }

        let snapshot = UsageSnapshot(
            generatedAt: generatedAt,
            source: .cloud,
            metrics: metrics
        )
        return MacSnapshot(macId: macId, label: label, snapshot: snapshot)
    }
}
