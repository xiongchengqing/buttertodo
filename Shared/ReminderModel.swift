import Foundation
import SQLite3
import UserNotifications

/// 待办模型:稳定 id 持久化在 App Group SQLite 里,锁屏卡片的圆圈靠它定位。
struct ReminderItem: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var title: String
    var isDone = false
    /// 可选的到期提醒时间(触发本地通知)
    var dueDate: Date?
}

/// 存储层:本地 SQLite(WAL 模式,App 与 Widget 扩展并发读写)+
/// iCloud KVS 镜像(带 modifiedAt 时间戳,最新胜出,跨设备同步)。
enum ReminderDataStore {
    static let suiteName = "group.com.example.remindify"
    private static let kvsKey = "todos"

    // MARK: - 旗标(保留在 UserDefaults)

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - 待办读写

    static func load() -> [ReminderItem] {
        migrateUserDefaultsIfNeeded()
        mergeFromCloudIfNeeded()
        return readAll()
    }

    static func save(_ items: [ReminderItem]) {
        writeAll(items)
        let now = Date().timeIntervalSince1970
        setMetaValue(now, forKey: "lastModifiedAt")
        mirrorToCloud(items, modifiedAt: now)
    }

    /// 锁屏/灵动岛圆圈的原地勾选:翻转状态后同步其到期提醒通知。
    static func toggle(id: String) {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        save(items)
        ReminderNotifications.sync(for: items[index])
    }

    // MARK: - SQLite

    private static var database: OpaquePointer?

    private static var databasePath: String {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = container.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("buttertodo.sqlite").path
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func connection() -> OpaquePointer? {
        if let database { return database }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &handle, flags, nil) == SQLITE_OK,
              let opened = handle else {
            sqlite3_close(handle)
            return nil
        }
        database = opened
        sqlite3_exec(opened, """
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=2000;
        CREATE TABLE IF NOT EXISTS todos (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            isDone INTEGER NOT NULL DEFAULT 0,
            dueDate REAL,
            sortIndex INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """, nil, nil, nil)
        return database
    }

    private static func readAll() -> [ReminderItem] {
        guard let db = connection() else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT id, title, isDone, dueDate FROM todos ORDER BY sortIndex", -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var items: [ReminderItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let title = String(cString: sqlite3_column_text(statement, 1))
            let isDone = sqlite3_column_int(statement, 2) != 0
            let dueDate: Date? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            items.append(ReminderItem(id: id, title: title, isDone: isDone, dueDate: dueDate))
        }
        return items
    }

    private static func writeAll(_ items: [ReminderItem]) {
        guard let db = connection() else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM todos", nil, nil, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(
            db, "INSERT INTO todos (id, title, isDone, dueDate, sortIndex) VALUES (?, ?, ?, ?, ?)",
            -1, &statement, nil
        )
        for (index, item) in items.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, item.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, item.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 3, item.isDone ? 1 : 0)
            if let due = item.dueDate {
                sqlite3_bind_double(statement, 4, due.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_int(statement, 5, Int32(index))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private static func metaValue(_ key: String) -> Double? {
        guard let db = connection() else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        defer { sqlite3_finalize(statement) }
        var value: Double?
        if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            value = Double(String(cString: text))
        }
        return value
    }

    private static func setMetaValue(_ value: Double, forKey key: String) {
        guard let db = connection() else { return }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(
            db, "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            -1, &statement, nil
        )
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, String(value), -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    // MARK: - 旧 JSON 迁移

    /// 首次运行时把旧 UserDefaults JSON 数据迁移进 SQLite(只执行一次)。
    private static func migrateUserDefaultsIfNeeded() {
        guard metaValue("migratedFromUserDefaults") == nil else { return }
        defer { setMetaValue(1, forKey: "migratedFromUserDefaults") }
        guard let data = defaults.data(forKey: "reminders"),
              let items = try? JSONDecoder().decode([ReminderItem].self, from: data),
              !items.isEmpty else { return }
        writeAll(items)
    }

    // MARK: - iCloud KVS 镜像

    private struct CloudEnvelope: Codable {
        var modifiedAt: Double
        var items: [ReminderItem]
    }

    private static func mirrorToCloud(_ items: [ReminderItem], modifiedAt: Double) {
        let envelope = CloudEnvelope(modifiedAt: modifiedAt, items: items)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: kvsKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// 其他设备通过 iCloud 写入了更新的数据时,合并到本地 SQLite。
    /// 本地有更新的修改时不覆盖(最新胜出)。
    static func mergeFromCloudIfNeeded() {
        let kvs = NSUbiquitousKeyValueStore.default
        guard let data = kvs.data(forKey: kvsKey),
              let envelope = try? JSONDecoder().decode(CloudEnvelope.self, from: data) else { return }
        let localModified = metaValue("lastModifiedAt") ?? 0
        guard envelope.modifiedAt > localModified + 0.5 else { return }
        writeAll(envelope.items)
        setMetaValue(envelope.modifiedAt, forKey: "lastModifiedAt")
    }

    // MARK: - Live Activity 状态

    /// 由当前待办列表生成 Live Activity 内容:卡片最多展示 2 条未完成,徽标为真实待完成数。
    static func contentState(from items: [ReminderItem]) -> ReminderActivityAttributes.ContentState {
        let pending = items.filter { !$0.isDone }
        let shown = pending.prefix(2)
        return .init(
            items: shown.map {
                .init(id: $0.id, title: $0.title, isDone: $0.isDone)
            },
            doneCount: items.count - pending.count,
            pendingCount: pending.count,
            hiddenCount: max(0, pending.count - shown.count)
        )
    }
}
