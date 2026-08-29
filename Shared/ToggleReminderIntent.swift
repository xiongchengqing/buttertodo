import AppIntents
import ActivityKit

/// 锁屏卡片上圆圈的点击动作:在 Widget 扩展进程里直接改共享存储并刷新 Live Activity,
/// 不打开 App。需要 iOS 17.2+(LiveActivityIntent)。
struct ToggleReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete reminder"

    @Parameter(title: "Reminder ID")
    var id: String

    init() {}

    init(id: String) {
        self.id = id
    }

    func perform() async throws -> some IntentResult {
        ReminderDataStore.toggle(id: id)
        let state = ReminderDataStore.contentState(from: ReminderDataStore.load())
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in Activity<ReminderActivityAttributes>.activities {
            if state.pendingCount == 0 {
                // 最后一条被勾掉:收起横幅,而不是继续展示 0 待办
                await activity.end(content, dismissalPolicy: .immediate)
            } else {
                await activity.update(content)
            }
        }
        // 通知主 App 存储已变化,前台界面立即同步
        StoreChangeSignal.post()
        return .result()
    }
}
