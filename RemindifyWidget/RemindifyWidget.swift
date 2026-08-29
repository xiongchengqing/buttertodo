import WidgetKit
import SwiftUI
import ActivityKit

@main
struct RemindifyWidgetBundle: WidgetBundle {
    var body: some Widget {
        ReminderLiveActivity()
    }
}

struct ReminderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReminderActivityAttributes.self) { context in
            LockScreenReminderView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "checklist")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.items.first?.title ?? String(localized: "All done 🎉"))
                        .font(.headline)
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.pendingCount) items to do")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "checklist")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                Text("\(context.state.pendingCount)")
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "checklist")
                    .foregroundStyle(.orange)
            }
        }
        .contentMarginsDisabled()
    }
}

/// 参照系统提醒事项风格的锁屏卡片:黑色背景、右上角计数徽标、橙色清单图标与待办行。
/// 圆圈是 Button(intent:) —— 点击由 ToggleReminderIntent 在扩展进程里原地勾选,不打开 App;
/// 卡片其余区域通过 widgetURL 兜底跳进 App。
struct LockScreenReminderView: View {
    let context: ActivityViewContext<ReminderActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text("ButterTodo")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(context.state.pendingCount)")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(white: 0.23)))
            }

            ForEach(context.state.items) { item in
                HStack(spacing: 14) {
                    Button(intent: ToggleReminderIntent(id: item.id)) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.orange, lineWidth: 2.5)
                                .frame(width: 25, height: 25)
                            if item.isDone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Text(item.title)
                        .font(.system(size: 21))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }

            if context.state.hiddenCount > 0 {
                HStack {
                    Spacer()
                    Text("…and \(context.state.hiddenCount) more")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .padding(20)
        .containerBackground(for: .widget) {
            Color.black
        }
        .widgetURL(URL(string: "remindify://open"))
    }
}
