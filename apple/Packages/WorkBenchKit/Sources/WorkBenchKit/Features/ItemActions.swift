import SwiftUI

enum ItemAction: Equatable {
  case focus, move, restore, schedule, convert, associate, abandon, archive, delete
  case importance(Int)
}

/// Actual SwiftUI content: native Menu/ControlGroup bridging cannot preserve this palette.
struct ItemActionPanel: View {
  let item: WorkspaceItem
  let select: (ItemAction) -> Void
  private var isTask: Bool { item.entity == .tasks }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if isTask {
        if item.status == "todo" {
          let dueToday = isTaskDueForToday(item, day: Clock.day())
          action("开始专注", symbol: "play", .focus)
          action(dueToday ? "移到以后" : "加入今日", symbol: dueToday ? "calendar" : "sun.max", .move)
          action("安排时间", symbol: "clock", .schedule)
        } else {
          action("恢复到今日", symbol: "arrow.uturn.backward", .restore)
        }
        Divider().padding(.vertical, 4)
        VStack(alignment: .leading, spacing: 4) {
          Text("重要程度").font(.caption).foregroundStyle(.secondary)
          TaskImportanceChoices(selected: item.importance) { select(.importance($0)) }
            .frame(maxWidth: .infinity)
        }.padding(.horizontal, WorkbenchDesign.Space.small)
          .padding(.vertical, 4)
        Divider().padding(.vertical, 4)
      } else {
        action("加入今日任务", symbol: "sun.max", .convert)
      }
      action("关联", symbol: "link", .associate)
      if isTask && item.status == "todo" { action("放弃", symbol: "xmark", .abandon) }
      if !isTask {
        action(item.status == "archived" ? "恢复" : "归档", symbol: "archivebox", .archive)
      }
      Divider().padding(.vertical, 4)
      action("删除", symbol: "trash", .delete, destructive: true)
    }.padding(WorkbenchDesign.Space.small)
      .frame(width: WorkbenchDesign.ItemActions.width)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("item.action.panel")
  }
  private func action(
    _ title: String, symbol: String, _ value: ItemAction, destructive: Bool = false
  ) -> some View {
    ItemActionButton(title: title, symbol: symbol, destructive: destructive) { select(value) }
  }
}
private struct ItemActionButton: View {
  let title: String
  let symbol: String
  let destructive: Bool
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(role: destructive ? .destructive : nil, action: action) {
      Label(title, systemImage: symbol)
        .font(.body).frame(
          maxWidth: .infinity, minHeight: WorkbenchDesign.ItemActions.actionHeight,
          alignment: .leading
        )
        .padding(.horizontal, WorkbenchDesign.Space.small)
        .contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(destructive ? Color.red : .primary)
      .background(hovering ? WorkbenchDesign.fieldBackground : .clear, in: .rect(cornerRadius: 6))
      .onHover { hovering = $0 }
  }
}
struct TaskImportanceChoices: View {
  let selected: Int
  let select: (Int) -> Void
  var body: some View {
    HStack(spacing: 4) {
      ForEach(1...5, id: \.self) { level in
        Button {
          select(level)
        } label: {
          ZStack {
            Circle().fill(importanceColor(level))
              .frame(
                width: WorkbenchDesign.ItemActions.swatchDiameter,
                height: WorkbenchDesign.ItemActions.swatchDiameter)
            if selected == level {
              Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
              Circle().strokeBorder(importanceColor(level), lineWidth: 2)
                .frame(
                  width: WorkbenchDesign.ItemActions.swatchDiameter + 8,
                  height: WorkbenchDesign.ItemActions.swatchDiameter + 8)
            }
          }.frame(
            width: WorkbenchDesign.ItemActions.swatchTarget,
            height: WorkbenchDesign.ItemActions.swatchTarget
          )
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel("重要程度 \(level)，共五级")
          .accessibilityValue(selected == level ? "已选中" : "未选中")
          .accessibilityAddTraits(selected == level ? .isSelected : [])
      }
    }.fixedSize(horizontal: true, vertical: false)
  }
}
