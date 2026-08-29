import UIKit

/// 全局点击手势:键盘弹出时,点击「输入栏」和「TodoList 卡片」以外的区域
/// (标题、卡片四周灰边、卡片下方空白等)收起键盘。
/// 键盘位于独立窗口,本手势天然收不到键盘上的点击。
/// cancelsTouchesInView = false,不干扰列表点击、滑动删除等原有手势。
/// 排除区域由 App 侧实时同步(输入栏 frame + 列表卡片 frame),纯几何判断,无竞态。
final class KeyboardTapDismissing: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardTapDismissing()

    /// 底部输入栏(含输入框与添加按钮)的全局 frame
    var inputBarFrame: CGRect = .zero
    /// 待办列表视图的全局 frame
    var listFrame: CGRect = .zero

    private weak var installedWindow: UIWindow?

    func installIfNeeded() {
        guard installedWindow == nil,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                  .first else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        installedWindow = window
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognzier: UIGestureRecognizer
    ) -> Bool { true }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let window = gesture.view else { return }
        let location = gesture.location(in: window)

        if inputBarFrame.contains(location) { return }
        if listFrame != .zero, listFrame.contains(location) { return }

        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}
