import CoreFoundation

/// 跨进程信号:Widget 扩展改完共享存储后通知主 App 立即重载,
/// 解决"灵动岛原地勾选后,前台 App 列表不刷新"的问题。
enum StoreChangeSignal {
    static let name = "com.example.remindify.storageChanged"

    static func post() {
        DarwinSignal.shared.post(name)
    }

    static func observe(onMain handler: @escaping () -> Void) {
        DarwinSignal.shared.observe(name) {
            DispatchQueue.main.async(execute: handler)
        }
    }
}

/// Darwin 通知的 Swift 封装(C 回调通过指针桥接回实例)。
final class DarwinSignal: NSObject {
    static let shared = DarwinSignal()

    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private var handler: (() -> Void)?
    private var observedName: CFString?

    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            center, CFNotificationName(name as CFString), nil, nil, true
        )
    }

    func observe(_ name: String, handler: @escaping () -> Void) {
        self.handler = handler
        observedName = name as CFString
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let signal = Unmanaged<DarwinSignal>
                    .fromOpaque(observer).takeUnretainedValue()
                signal.handler?()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        if let observedName {
            CFNotificationCenterRemoveObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(observedName),
                nil
            )
        }
    }
}
