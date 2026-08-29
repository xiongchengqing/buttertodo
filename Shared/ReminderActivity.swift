import Foundation
import ActivityKit

/// 卡片上一行待办:id 供锁屏圆圈的 App Intent 原地定位并勾选。
struct ReminderContentItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var isDone: Bool
}

/// App 与 Widget 扩展共享的 Live Activity 属性定义。
struct ReminderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 展示在卡片上的待办（最多 2 条未完成）
        var items: [ReminderContentItem]
        var doneCount: Int
        var pendingCount: Int
        /// 未展示的剩余待办数（超出 2 条的部分）
        var hiddenCount: Int = 0
    }

    var totalReminders: Int
}
