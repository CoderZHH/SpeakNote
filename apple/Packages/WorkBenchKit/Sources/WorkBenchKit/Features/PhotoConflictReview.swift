import SwiftUI

struct PhotoConflictReview: View {
  let conflict: SyncConflict
  @Environment(AppSession.self) private var session
  @State private var expanded: Bool
  @State private var saving = false
  @State private var issue: String?
  init(conflict: SyncConflict, initiallyExpanded: Bool = false) {
    self.conflict = conflict
    _expanded = State(initialValue: initiallyExpanded)
  }
  var body: some View {
    DisclosureGroup(session.photos?.snapshot.order(conflict.recordID)?.brand ?? "共享修改", isExpanded: $expanded) {
      ForEach(
        PhotoField.allCases.filter {
          RecordMerge.photoConflictFields(base: conflict.base, local: conflict.local,
            remote: conflict.remote).contains($0.rawValue)
        }
      ) { field in
        VStack(alignment: .leading, spacing: 5) {
          Text(field.title).font(.subheadline.weight(.medium))
          comparison("本机", value: text(conflict.local[field.rawValue], field: field))
          comparison("共享", value: text(conflict.remote[field.rawValue], field: field))
        }
      }
      if conflict.entity == "workflow" {
        LabeledContent(
          "本机", value: stageTitle(conflict.local))
        LabeledContent(
          "共享", value: stageTitle(conflict.remote))
      }
      if conflict.entity == "order", !conflict.base.isNull {
        Text("只选择有分歧的字段，其他修改会保留。").font(.footnote).foregroundStyle(.secondary)
      }
      Button("保留本机修改") { choose(true) }.disabled(saving)
      Button("使用共享版本") { choose(false) }.disabled(saving)
      if saving { ProgressView().controlSize(.small) }
      if let issue {
        Label(issue, systemImage: "exclamationmark.circle").font(.footnote)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  private func comparison(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.body).foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  func choose(_ local: Bool) {
    saving = true
    issue = nil
    Task {
      defer { saving = false }
      do {
        _ = try await session.photos?.perform(
          .resolveConflict(id: conflict.id, keepLocal: local, expectedRevision: conflict.revision))
        session.scheduleSync()
      } catch {
        try? await session.photos?.refresh()
        issue = error.localizedDescription
      }
    }
  }
  private func stageTitle(_ value: JSONValue) -> String {
    if !value["completed_at"].isNull { return "已完成" }
    return PhotoStage(rawValue: value["stage"].string)?.title ?? "未设置"
  }
  func text(_ value: JSONValue, field: PhotoField) -> String {
    if field == .images { return "\(value.array.count) 张图片" }
    if [.postage, .commission].contains(field) {
      return value.isNull ? "未填写" : "¥" + String(format: "%.2f", Double(value.int) / 100)
    }
    return value.string.isEmpty ? "未填写" : value.string
  }
}
