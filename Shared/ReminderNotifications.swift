import UserNotifications

/// 待办到期提醒的本地通知调度(App 与 Widget 扩展共用,扩展进程亦可取消/重排)。
enum ReminderNotifications {
    /// 首次调度会触发系统授权弹窗;授权后写入待触发请求。
    static func requestAuthorizationThenSchedule(id: String, title: String, date: Date) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            schedule(id: id, title: title, date: date)
        }
    }

    static func schedule(id: String, title: String, date: Date) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    static func remove(id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// 依据条目状态同步其到期提醒通知:未完成且到期时间在未来才(重新)调度,否则移除。
    static func sync(for item: ReminderItem) {
        if !item.isDone, let date = item.dueDate {
            requestAuthorizationThenSchedule(id: item.id, title: item.title, date: date)
        } else {
            remove(id: item.id)
        }
    }
}

