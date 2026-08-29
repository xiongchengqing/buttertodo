import Foundation
import ActivityKit

/// 管理提醒列表(持久化到 App Group 存储),并把当前状态同步到锁屏 Live Activity。
final class ReminderStore: ObservableObject {
    @Published var reminders: [ReminderItem] {
        didSet { ReminderDataStore.save(reminders) }
    }
    @Published private(set) var isActivityActive = false
    /// 用户通过铃铛手动关闭过横幅:自动挂出逻辑尊重该选择,直到手动重新开启
    @Published var bannerDisabledByUser: Bool {
        didSet { ReminderDataStore.setBool(bannerDisabledByUser, forKey: "bannerDisabledByUser") }
    }

    private var activity: Activity<ReminderActivityAttributes>?

    init() {
        // 自动化测试钩子:simctl launch 会吞掉 "--" 开头的参数,故同时兼容无横杠参数与环境变量
        let launchArgs = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let wantsEmpty = launchArgs.contains("buttertodo-empty") || env["BUTTERTODO_EMPTY"] == "1"
        let wantsTestNotification = launchArgs.contains("buttertodo-testnotif")
            || env["BUTTERTODO_TESTNOTIF"] == "1"
        if wantsEmpty {
            ReminderDataStore.save([])
        }
        // 测试钩子:注入一条 75 秒后到期的待办
        var testNotificationItem: ReminderItem?
        if wantsTestNotification {
            let due = Date().addingTimeInterval(75)
            let item = ReminderItem(title: "Test notification", dueDate: due)
            testNotificationItem = item
        }
        // 测试钩子:注入旧版 JSON 数据验证迁移
        if env["BUTTERTODO_LEGACY_JSON"] == "1" {
            let legacy: [String: Any] = [
                "dueDate": NSNull(),
                "id": "legacy-1",
                "isDone": false,
                "title": "Legacy migration test",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: [legacy]) {
                ReminderDataStore.defaults.set(data, forKey: "reminders")
                ReminderDataStore.defaults.removeObject(forKey: "didSeedDefaults")
            }
        }
        var loaded = ReminderDataStore.load()
        let isFirstLaunch = loaded.isEmpty && !ReminderDataStore.bool(forKey: "didSeedDefaults")
        if isFirstLaunch {
            loaded = [
                .init(title: String(localized: "Welcome to ButterTodo")),
                .init(title: String(localized: "Tap the circle to mark as done")),
                .init(title: String(localized: "Tap the circle on the lock screen to complete it")),
                .init(title: String(localized: "Swipe left to delete")),
            ]
        }
        if let item = testNotificationItem {
            loaded.insert(item, at: 0)
            ReminderNotifications.requestAuthorizationThenSchedule(
                id: item.id,
                title: item.title,
                date: item.dueDate ?? Date().addingTimeInterval(60)
            )
        }
        if isFirstLaunch {
            // 落盘放在钩子插入之后,避免测试条目被随后的 reload 冲掉
            ReminderDataStore.save(loaded)
            ReminderDataStore.setBool(true, forKey: "didSeedDefaults")
        }
        bannerDisabledByUser = ReminderDataStore.bool(forKey: "bannerDisabledByUser")
        reminders = loaded
    }

    /// Intent 可能已在后台改过存储,回到前台时重新加载保持一致。
    func reload() {
        reminders = ReminderDataStore.load()
    }

    private var pendingReminders: [ReminderItem] {
        reminders.filter { !$0.isDone }
    }

    private func makeContent() -> ActivityContent<ReminderActivityAttributes.ContentState> {
        ActivityContent(state: ReminderDataStore.contentState(from: reminders), staleDate: nil)
    }

    func startActivity() {
        // 用户手动关闭过横幅时,不再自动挂出
        guard !bannerDisabledByUser else {
            isActivityActive = false
            return
        }
        // 没有待办时不挂横幅
        guard !pendingReminders.isEmpty else {
            isActivityActive = false
            return
        }
        // 已有活动直接复用并刷新内容,避免每次启动横幅闪跳重建
        if let existing = Activity<ReminderActivityAttributes>.activities.first {
            activity = existing
            isActivityActive = true
            let content = makeContent()
            Task { await existing.update(content) }
            return
        }
        let attributes = ReminderActivityAttributes(totalReminders: reminders.count)
        activity = try? Activity.request(attributes: attributes, content: makeContent())
        isActivityActive = activity != nil
    }

    func endActivity() {
        guard let activity else { return }
        self.activity = nil
        isActivityActive = false
        Task { await activity.end(makeContent(), dismissalPolicy: .immediate) }
    }

    /// 列表变化后把最新状态推送到正在展示的活动;
    /// 全部完成时自动收起,从空重新有待办时自动重建(除非用户手动关闭过横幅)。
    func syncActivity() {
        if pendingReminders.isEmpty {
            endActivity()
        } else if let activity {
            let content = makeContent()
            Task { await activity.update(content) }
        } else if !bannerDisabledByUser {
            startActivity()
        }
    }

    /// 重命名待办标题(长按编辑)。
    func rename(id: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].title = trimmed
        syncReminderNotification(reminders[index])
        syncActivity()
    }

    /// 设置/清除到期提醒时间。
    func setDueDate(id: String, date: Date?) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].dueDate = date
        syncReminderNotification(reminders[index])
        syncActivity()
    }

    /// 勾选/取消勾选:完成后取消到期提醒,勾回未完成则恢复。
    func toggleDone(id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isDone.toggle()
        syncReminderNotification(reminders[index])
        syncActivity()
    }

    /// 深链处理:remindify://toggle/<id> 直接完成对应待办。
    func complete(id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isDone = true
        syncReminderNotification(reminders[index])
        syncActivity()
    }

    /// 根据条目状态同步其到期提醒通知:未完成且有到期时间才(重新)调度,否则移除。
    private func syncReminderNotification(_ item: ReminderItem) {
        ReminderNotifications.sync(for: item)
    }
}
