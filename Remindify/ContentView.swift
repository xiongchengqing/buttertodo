import SwiftUI
import UIKit

private extension View {
    /// 条件修饰符:仅满足条件时应用变换
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// App 内主题色
private extension Color {
    /// 空心圆圈边框 #FC6D06
    static let circleBorder = Color(red: 0xFC / 255.0, green: 0x6D / 255.0, blue: 0x06 / 255.0)
    /// 已勾选圆圈填充 #61C13F
    static let circleCheckedFill = Color(red: 0x61 / 255.0, green: 0xC1 / 255.0, blue: 0x3F / 255.0)
}

private struct InputBarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// 列表视图的 frame(点击收起键盘的排除区域;只在布局变化时更新,不随编辑动画抖动)
private struct ListFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// 编辑待办的半屏表单(alert 不支持 Toggle/DatePicker,必须用 sheet 承载)
private struct EditReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, Date?) -> Void
    @State private var title: String
    @State private var remindMe: Bool
    @State private var dueDate: Date

    init(item: ReminderItem, onSave: @escaping (String, Date?) -> Void) {
        _title = State(initialValue: item.title)
        _remindMe = State(initialValue: item.dueDate != nil)
        _dueDate = State(initialValue: item.dueDate ?? Date().addingTimeInterval(3600))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("New reminder…", text: $title)
                }
                Section {
                    Toggle("Remind me", isOn: $remindMe)
                    if remindMe {
                        DatePicker("Due date", selection: $dueDate)
                    }
                }
            }
            .navigationTitle("Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, remindMe ? dueDate : nil)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 撤销删除的记录
private struct DeletedReminders: Equatable {
    var items: [ReminderItem]
    var insertIndex: Int
}

struct ContentView: View {
    @StateObject private var store = ReminderStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.editMode) private var editMode
    @FocusState private var newTitleFieldFocused: Bool
    @State private var newTitle = ""
    @State private var listFrame: CGRect = .zero
    @State private var inputBarFrame: CGRect = .zero
    @State private var deletedReminders: DeletedReminders?
    @State private var editingReminder: ReminderItem?

    private func syncTapDismissFrames() {
        KeyboardTapDismissing.shared.inputBarFrame = inputBarFrame
        KeyboardTapDismissing.shared.listFrame = listFrame
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.reminders.isEmpty {
                    emptyState
                } else {
                    todoList
                }
            }
            .navigationTitle("ButterTodo")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // 不加动画:瞬时切换,避免系统编辑控件(⊖/≡)动画进场的闪现
                        toggleEditMode()
                    } label: {
                        editModeButtonIcon
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    bannerToggleButton
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .overlay(alignment: .bottom) { undoToast }
            .task(id: deletedReminders) {
                guard deletedReminders != nil else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation { deletedReminders = nil }
            }
            .onOpenURL { url in
                // 锁屏卡片的 widgetURL 兜底入口;remindify://toggle/<id> 直接完成对应待办
                guard url.scheme == "remindify" else { return }
                if url.host == "toggle", let id = url.pathComponents.last, id != "/" {
                    store.complete(id: id)
                }
            }
            .onAppear {
                KeyboardTapDismissing.shared.installIfNeeded()
                StoreChangeSignal.observe { store.reload() }
                // 其他设备通过 iCloud 写入更新的待办时,合并并刷新
                NotificationCenter.default.addObserver(
                    forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: NSUbiquitousKeyValueStore.default,
                    queue: .main
                ) { _ in
                    ReminderDataStore.mergeFromCloudIfNeeded()
                    store.reload()
                }
                syncTapDismissFrames()
                if !store.isActivityActive {
                    store.startActivity()
                }
            }
            .onChange(of: store.reminders) { _, _ in syncTapDismissFrames() }
            .onChange(of: inputBarFrame) { _, _ in syncTapDismissFrames() }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            .sheet(item: $editingReminder) { item in
                EditReminderSheet(item: item) { newTitle, dueDate in
                    store.rename(id: item.id, to: newTitle.trimmingCharacters(in: .whitespaces))
                    store.setDueDate(id: item.id, date: dueDate)
                }
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            store.reload()
            if !store.isActivityActive {
                store.startActivity()
            }
        } else {
            // 离开主界面(切后台/锁屏)时自动收起键盘
            newTitleFieldFocused = false
        }
    }

    @ViewBuilder
    private var editModeButtonLabel: some View {
        if editMode?.wrappedValue == .active {
            Text("Done")
        } else {
            Text("Edit")
        }
    }

    /// 编辑模式切换按钮:排序图标 / 完成勾,无障碍标签沿用本地化文案
    @ViewBuilder
    private var editModeButtonIcon: some View {
        if editMode?.wrappedValue == .active {
            Image(systemName: "checkmark")
                .accessibilityLabel(Text("Done"))
        } else {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel(Text("Edit"))
        }
    }

    private func toggleEditMode() {
        guard let editMode else { return }
        if editMode.wrappedValue == .active {
            editMode.wrappedValue = .inactive
        } else {
            editMode.wrappedValue = .active
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No todos", systemImage: "checklist")
        } description: {
            Text("Create a new reminder below")
        }
    }

    // MARK: - 待办列表

    private var todoList: some View {
        List {
            // 单一稳定 ForEach:结构不变才能可靠挂载拖动排序手柄
            ForEach($store.reminders) { $reminder in
                rowContent($reminder)
            }
            .onMove { from, to in
                withAnimation {
                    store.reminders.move(fromOffsets: from, toOffset: to)
                }
                store.syncActivity()
            }
            // 普通模式禁用拖动排序(新版 List 挂载 onMove 后默认支持长按拖动),
            // 仅编辑模式允许;删除改为 swipeActions(仅普通模式可滑动触发)
            .moveDisabled(editMode?.wrappedValue != .active)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ListFrameKey.self,
                    value: geo.frame(in: .global)
                )
            }
        )
        .onPreferenceChange(ListFrameKey.self) { listFrame = $0 }
        .listStyle(.insetGrouped)
        .environment(\.editMode, editMode)
        .scrollDismissesKeyboard(.interactively)
    }

    /// 单行内容。两种模式下修饰符栈结构完全一致(手势永远挂载,编辑模式内短路),
    /// 切换模式时行不重建 —— 这是系统拖动手柄稳定显示、不出现 fade-out 的关键。
    private func rowContent(_ reminder: Binding<ReminderItem>) -> some View {
        let isEditing = editMode?.wrappedValue == .active
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: reminder.wrappedValue.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(reminder.wrappedValue.isDone ? Color.circleCheckedFill : Color.circleBorder)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.wrappedValue.title)
                    .strikethrough(reminder.wrappedValue.isDone, color: .secondary)
                    .foregroundStyle(reminder.wrappedValue.isDone ? Color.secondary : Color.primary)
                if let due = reminder.wrappedValue.dueDate, !reminder.wrappedValue.isDone {
                    HStack(spacing: 0) {
                        Image(systemName: "bell")
                        Text("  " + due.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                // 编辑模式的拖动手柄:静态图标硬切显示,永不 fade
                if isEditing {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard !isEditing else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                store.toggleDone(id: reminder.wrappedValue.id)
            }
        })
        .contextMenu {
            if !isEditing {
                Button {
                    editingReminder = reminder.wrappedValue
                } label: {
                    Label("Edit reminder", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    if let index = store.reminders.firstIndex(where: { $0.id == reminder.wrappedValue.id }) {
                        deleteItems(at: IndexSet(integer: index))
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                if let index = store.reminders.firstIndex(where: { $0.id == reminder.wrappedValue.id }) {
                    deleteItems(at: IndexSet(integer: index))
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - 横幅开关(尊重手动关闭)

    private var bannerToggleButton: some View {
        Button {
            if store.isActivityActive {
                store.bannerDisabledByUser = true
                store.endActivity()
            } else {
                store.bannerDisabledByUser = false
                store.startActivity()
            }
        } label: {
            Label(
                "Live Activity",
                systemImage: store.bannerDisabledByUser
                    ? "bell.slash"
                    : (store.isActivityActive ? "bell.badge.fill" : "bell.badge")
            )
        }
        .foregroundStyle(store.isActivityActive && !store.bannerDisabledByUser ? Color.blue : Color.gray)
        .accessibilityIdentifier("liveActivityToggle")
    }

    // MARK: - 底部输入栏

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("New reminder…", text: $newTitle)
                .focused($newTitleFieldFocused)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addReminder)
                .accessibilityIdentifier("newReminderField")
            Button(action: addReminder) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("addButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: InputBarFrameKey.self,
                    value: geo.frame(in: .global)
                )
            }
        )
        .onPreferenceChange(InputBarFrameKey.self) { inputBarFrame = $0 }
    }

    // MARK: - 撤销删除 Toast

    @ViewBuilder private var undoToast: some View {
        if let undo = deletedReminders {
            HStack(spacing: 12) {
                Text("Deleted \(undo.items.count) reminders")
                    .font(.subheadline)
                Spacer()
                Button("Undo") {
                    restoreDeleted(undo)
                }
                .font(.subheadline.bold())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 动作

    private func addReminder() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        withAnimation {
            store.reminders.insert(ReminderItem(title: title), at: 0)
        }
        store.syncActivity()
        newTitle = ""
    }

    private func deleteItems(at offsets: IndexSet) {
        let removedItems = offsets.map { store.reminders[$0] }
        let insertIndex = offsets.first ?? 0
        withAnimation {
            store.reminders.remove(atOffsets: offsets)
        }
        removedItems.forEach { ReminderNotifications.remove(id: $0.id) }
        store.syncActivity()
        withAnimation {
            deletedReminders = DeletedReminders(items: removedItems, insertIndex: insertIndex)
        }
    }

    private func restoreDeleted(_ record: DeletedReminders) {
        withAnimation {
            var index = min(record.insertIndex, store.reminders.count)
            for item in record.items {
                store.reminders.insert(item, at: index)
                index += 1
                if !item.isDone, let date = item.dueDate {
                    ReminderNotifications.schedule(id: item.id, title: item.title, date: date)
                }
            }
        }
        store.syncActivity()
        deletedReminders = nil
    }
}

#Preview {
    ContentView()
}
