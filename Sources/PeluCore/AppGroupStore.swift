import Foundation

/// 共享 snapshot 給 Widget / Live Activity 用。
///
/// **同時寫檔案 + UserDefaults**：
/// - 檔案是 primary（跨 process 一致性可靠，UserDefaults App Group 跨 process 快取常出包）
/// - UserDefaults 是 fallback（避免 widget extension binary 還是舊版時讀不到資料）
public struct AppGroupStore {
    public static let groupIdentifier = "group.org.tobywu.pelu"

    private let aggregateURL: URL?
    private let defaults: UserDefaults?
    private let aggregateKey = "latestAggregateSnapshot"

    public init?(suiteName: String = AppGroupStore.groupIdentifier) {
        let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        let userDefaults = UserDefaults(suiteName: suiteName)

        guard containerURL != nil || userDefaults != nil else {
            return nil
        }

        self.init(containerURL: containerURL, defaults: userDefaults)
    }

    /// Lets tests point at a temp directory; un-entitled processes can't write
    /// to `~/Library/Group Containers` on recent macOS.
    init(containerURL: URL?, defaults: UserDefaults?) {
        self.aggregateURL = containerURL?.appendingPathComponent("latest-aggregate-snapshot.json")
        self.defaults = defaults
    }

    public func save(_ aggregate: AggregateSnapshot) throws {
        let data = try JSONEncoder.peluAPI.encode(aggregate)
        if let url = aggregateURL {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        }
        defaults?.set(data, forKey: aggregateKey)
    }

    public func loadLatestAggregate() throws -> AggregateSnapshot? {
        if let url = aggregateURL, FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder.peluAPI.decode(AggregateSnapshot.self, from: data)
        }
        if let data = defaults?.data(forKey: aggregateKey) {
            return try JSONDecoder.peluAPI.decode(AggregateSnapshot.self, from: data)
        }
        return nil
    }
}
