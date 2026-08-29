import SwiftUI
import UIKit
import UserNotifications

/// 让到期提醒在 App 处于前台时也以横幅形式展示(默认会被系统吞掉)。
final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationForegroundDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct RemindifyApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = NotificationForegroundDelegate.shared

        // 导航栏标题颜色 #2E343F(大标题与常规标题都要设置)
        let titleColor = UIColor(
            red: 0x2E / 255.0,
            green: 0x34 / 255.0,
            blue: 0x3F / 255.0,
            alpha: 1
        )
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.foregroundColor: titleColor]
        appearance.largeTitleTextAttributes = [.foregroundColor: titleColor]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

