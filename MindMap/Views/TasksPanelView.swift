import SwiftUI

/// The virtual "Tasks (N)" card on the canvas (XMind floating-topic look):
/// derived live from the map's tasks, not a topic, not in the layout or
/// the tree's undo. Header drag = move (undoable, saved); chevron =
/// collapse; rows: checkbox completes, click selects + scrolls to the topic.
struct TasksPanelView: View {
    let editor: EditorController
    let panel: TaskPanelContent
    let viewport: Viewport

    static let headerFillHex = "#EAF1FB"
    static let borderHex = "#C9D6E8"
    static let inkHex = ColorTheme.inkHex

    private var scale: CGFloat { viewport.scale }

    var body: some View {
        let drag = editor.taskPanelDrag ?? .zero
        let screen = viewport.toScreen(panel.frame).offsetBy(dx: drag.width, dy: drag.height)
        let shape = RoundedRectangle(cornerRadius: TaskPanelLayout.cornerRadius * scale, style: .continuous)
        VStack(spacing: 0) {
            header
            if !panel.isCollapsed {
                ForEach(panel.visibleEntries) { entry in
                    TaskPanelRow(editor: editor, entry: entry, scale: scale, isSelected: editor.selectedID == entry.id)
                        .transition(.opacity)
                }
                if panel.hasFooter { footer }
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .top)
        .background(shape.fill(Color.white))
        .clipShape(shape)
        .overlay(shape.stroke(Color(hex: Self.borderHex), lineWidth: max(1, 1.25 * scale)))
        .shadow(color: .black.opacity(0.10), radius: 8 * scale, y: 2 * scale)
        .position(x: screen.midX, y: screen.midY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks panel")
    }

    // MARK: Header (drag handle)

    private var header: some View {
        HStack(spacing: 6 * scale) {
            Button { editor.toggleTaskPanelCollapsed() } label: {
                Image(systemName: panel.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(Color(hex: Self.inkHex).opacity(0.6))
                    .frame(width: 18 * scale, height: 18 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(panel.isCollapsed ? "Expand" : "Collapse")
            Image(systemName: "checklist")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(Color(hex: "#2E7CF6"))
            Text("Tasks (\(panel.openCount))")
                .font(.system(size: 14.5 * scale, weight: .semibold))
                .foregroundStyle(Color(hex: Self.inkHex))
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Toggle("Show Completed", isOn: Binding(get: { editor.taskPanelShowsCompleted },
                                                       set: { editor.taskPanelShowsCompleted = $0 }))
                Button("Reset Position", systemImage: "arrow.uturn.backward.circle") {
                    editor.resetTaskPanelPosition()
                }
                .disabled(panel.isAutoPositioned || editor.isReadOnly)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundStyle(Color(hex: Self.inkHex).opacity(0.6))
                    .frame(width: 22 * scale, height: 18 * scale)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: TaskPanelLayout.headerHeight * scale)
        .background(Color(hex: Self.headerFillHex))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasView.space))
                .onChanged { editor.updateTaskPanelDrag($0.translation) }
                .onEnded { _ in editor.endTaskPanelDrag() }
        )
        .help(editor.isReadOnly ? "" : "Drag to move the Tasks panel")
    }

    private var footer: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { editor.taskPanelShowsAll.toggle() }
        } label: {
            Text(panel.hiddenCount > 0 ? "Show \(panel.hiddenCount) More" : "Show Less")
                .font(.system(size: 11.5 * scale, weight: .medium))
                .foregroundStyle(Color(hex: "#2E7CF6"))
                .frame(maxWidth: .infinity)
                .frame(height: TaskPanelLayout.footerHeight * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One task row: checkbox, branch color dot, priority + title, breadcrumb, due chip.
private struct TaskPanelRow: View {
    let editor: EditorController
    let entry: TaskEntry
    let scale: CGFloat
    let isSelected: Bool

    private var ink: Color { Color(hex: TasksPanelView.inkHex) }
    private var isDone: Bool { entry.task.isDone }

    var body: some View {
        HStack(spacing: 8 * scale) {
            TaskCheckboxView(isDone: isDone, size: 17 * scale, color: ink) { editor.togglePanelTask(entry.id) }
            Circle()
                .fill(Color(hex: editor.scene.colors[entry.id] ?? ColorTheme.rootColorHex))
                .frame(width: 7 * scale, height: 7 * scale)
            VStack(alignment: .leading, spacing: 1 * scale) {
                HStack(spacing: 3 * scale) {
                    if let priority = entry.task.priority {
                        Text(priority.mark)
                            .font(.system(size: 12.5 * scale, weight: .heavy))
                            .foregroundStyle(Color(hex: priority.colorHex).opacity(isDone ? 0.45 : 1))
                    }
                    Text(entry.text)
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundStyle(ink.opacity(isDone ? 0.45 : 1))
                        .strikethrough(isDone, color: ink.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !entry.breadcrumb.isEmpty {
                    Text(entry.breadcrumb)
                        .font(.system(size: 10.5 * scale))
                        .foregroundStyle(ink.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if let due = entry.task.dueDate {
                DueChipView(label: DueLabel(due: due, now: editor.now()), isDone: isDone, fontSize: 13, scale: scale,
                            textColor: ink)
            }
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: TaskPanelLayout.rowHeight * scale)
        .background(isSelected ? Color(hex: "#2E7CF6").opacity(0.10) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { editor.showTask(entry.id) }
        .contextMenu { TaskMenuItems(editor: editor, id: entry.id) }
        .help(entry.ancestors.isEmpty ? entry.text : (entry.ancestors + [entry.text]).joined(separator: " › "))
    }
}

/// Picker popover for a topic's due day: quick picks, calendar, Clear.
struct DueDatePicker: View {
    let editor: EditorController
    let id: UUID
    @State private var date: Date

    init(editor: EditorController, id: UUID) {
        self.editor = editor
        self.id = id
        _date = State(initialValue: editor.task(of: id)?.dueDate ?? editor.now())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Due Date").font(.headline)
            HStack {
                ForEach(DueQuickPick.allCases, id: \.self) { pick in
                    Button(pick.title) { finish(pick.date(from: editor.now())) }
                }
            }
            DatePicker("Due Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Clear", role: .destructive) { finish(nil) }
                    .disabled(editor.task(of: id)?.dueDate == nil)
                Spacer()
                Button("Cancel", role: .cancel) { editor.dueDatePickerID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { finish(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func finish(_ value: Date?) {
        editor.dueDatePickerID = nil
        editor.setTaskDueDate(value, for: id)
    }
}
