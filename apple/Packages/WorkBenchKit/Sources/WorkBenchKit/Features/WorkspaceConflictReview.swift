import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceConflictReview: View {
  let conflict: SyncConflict
  @Environment(AppSession.self) private var session
  @State private var saving = false
  @State private var issue: String?
  @State private var expanded = false
  @State private var exportDocument: JSONDocument?
  @State private var exporting = false

  init(conflict: SyncConflict, initiallyExpanded: Bool = false) {
    self.conflict = conflict
    _expanded = State(initialValue: initiallyExpanded)
  }

  private var proposed: JSONValue {
    RecordMerge.workspace(base: conflict.base, local: conflict.local, remote: conflict.remote,
      preferLocalConflicts: true).0
  }
  private var fields: [String] {
    Set(proposed.object.keys).union(conflict.remote.object.keys).filter {
      !["id", "profile", "repo_path", "updated_at"].contains($0) && proposed[$0] != conflict.remote[$0]
    }.sorted { (labels[$0] ?? $0) < (labels[$1] ?? $1) }
  }
  private var title: String {
    for key in ["title", "content", "name"] where !conflict.local[key].string.isEmpty {
      let line = String(conflict.local[key].string.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
      return String(line.prefix(40)) + (line.count > 40 ? "…" : "")
    }
    return "保留的修改"
  }
  private var canApplySaved: Bool {
    WorkspaceEntity(rawValue: conflict.entity) != nil && !conflict.local.object.isEmpty
  }

  var body: some View {
    DisclosureGroup(title, isExpanded: $expanded) {
      if !canApplySaved {
        Text("这份旧格式内容可以直接复制或导出留存。")
          .font(.footnote).foregroundStyle(.secondary)
      } else if conflict.remote.isNull {
        Text("当前条目已删除。恢复会沿用原条目的身份，避免再创建一份重复内容。")
          .font(.footnote).foregroundStyle(.secondary)
      } else if !conflict.base.isNull {
        Text("只替换下面有分歧的部分，其他修改会保留。")
          .font(.footnote).foregroundStyle(.secondary)
      }
      ForEach(fields, id: \.self) { field in
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
          Text(labels[field] ?? "其他内容").font(.subheadline.weight(.medium))
          comparison("当前", value: conflict.remote[field], field: field)
          comparison("保留", value: proposed[field], field: field)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if fields.isEmpty, !conflict.local.string.isEmpty {
        Text(conflict.local.string).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button(conflict.remote.isNull ? "保留当前状态" : "保留当前版本") { resolve(.current) }.disabled(saving)
        .accessibilityIdentifier("workspace.conflict.current")
      if canApplySaved {
        Button(conflict.remote.isNull ? "恢复这条记录" : "使用保留版本") { resolve(.saved) }.disabled(saving)
          .accessibilityIdentifier("workspace.conflict.saved")
      }
      if let entity = WorkspaceEntity(rawValue: conflict.entity),
        WorkspaceEngine.canCopyConflict(entity), !conflict.remote.isNull
      {
        Button("保留两份") { resolve(.keepBoth) }.disabled(saving)
          .accessibilityIdentifier("workspace.conflict.both")
      }
      Button("导出保留内容") {
        do {
          exportDocument = JSONDocument(data: try JSONValue.object([
            "entity": .string(conflict.entity), "recordID": .string(conflict.recordID),
            "saved": conflict.local, "current": conflict.remote, "base": conflict.base,
          ]).data())
          exporting = true
        } catch { issue = error.localizedDescription }
      }.disabled(saving)
      if saving { ProgressView().controlSize(.small) }
      if let issue {
        Label(issue, systemImage: "exclamationmark.circle").font(.footnote)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
      defaultFilename: "随口记-保留内容-" + Clock.day()) { result in
      if case .failure(let error) = result { issue = error.localizedDescription }
    }
  }

  private func comparison(_ label: String, value: JSONValue, field: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(display(value, field: field)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  private func resolve(_ choice: WorkspaceConflictChoice) {
    saving = true
    issue = nil
    Task {
      defer { saving = false }
      do {
        _ = try await session.workspace?.perform(.resolveConflict(id: conflict.id, choice: choice,
          expectedRevision: conflict.revision))
        session.scheduleSync()
      } catch {
        try? await session.workspace?.refresh()
        issue = error.localizedDescription
      }
    }
  }
  private func display(_ value: JSONValue, field: String) -> String {
    if value.isNull { return "未填写" }
    if field == "status" {
      return ["todo": "待完成", "done": "已完成", "abandoned": "已放弃", "active": "进行中",
        "paused": "已暂停", "inbox": "待整理", "processed": "已整理", "archived": "已归档", "ended": "已结束"][value.string] ?? value.string
    }
    if field.hasSuffix("_at") || field == "active_since", let date = try? Clock.parse(value.string) {
      let formatter = DateFormatter()
      formatter.calendar = Clock.calendar
      formatter.timeZone = Clock.calendar.timeZone
      formatter.dateFormat = "yyyy年M月d日 HH:mm"
      return formatter.string(from: date)
    }
    if field.hasSuffix("_id"), let entity = ["space_id": WorkspaceEntity.spaces,
      "collection_id": .collections, "project_id": .projects,
      "learning_id": .learning, "course_id": .courses, "source_note_id": .notes,
      "semester_id": .semesters, "task_id": .tasks, "note_id": .notes, "parent_id": .lessons,
      "account_id": .accounts][field], let item = session.workspace?.snapshot.item(entity, value.string)
    { return item.title.isEmpty ? item[.name].string : item.title }
    if case .string(let text) = value { return text.isEmpty ? "未填写" : text }
    return (try? value.json()) ?? "未填写"
  }

  private var labels: [String: String] { [
    "title": "名称", "content": "正文", "name": "名称", "notes": "备注", "remark": "备注",
    "description": "说明", "status": "状态", "completed_at": "完成时间", "abandoned_at": "放弃时间",
    "created_at": "创建时间", "planned_date": "安排日期", "due_date": "截止日期",
    "start_time": "开始时间", "end_time": "结束时间", "reminder_enabled": "提醒", "reminder_at": "提醒时间",
    "importance": "重要程度", "priority": "优先级", "important": "重要标记", "estimate": "预计时长",
    "space_id": "空间", "collection_id": "卡片", "symbol": "图标",
    "project_id": "项目", "learning_id": "学习", "course_id": "课程", "source_note_id": "来源记录",
    "semester_id": "学期", "task_id": "任务", "note_id": "记录", "parent_id": "上级步骤",
    "account_id": "账号", "tags": "标签", "day": "日期", "teacher": "教师", "code": "课程编号",
    "room": "教室", "weekday": "星期", "weeks": "教学周", "period_start": "开始节次",
    "period_end": "结束节次", "periods": "作息", "first_monday": "学期首日", "position": "顺序",
    "done": "完成状态", "resume_hint": "接续位置", "platform": "平台", "color": "颜色",
    "started_at": "开始时间", "ended_at": "结束时间", "elapsed_seconds": "专注时长",
    "untracked_seconds": "未分段时长", "active_since": "计时起点", "focus_id": "专注记录",
    "file_key": "附件文件", "mime": "文件类型", "size": "文件大小", "sha256": "文件校验",
    "captured_at": "采集时间", "followers": "粉丝数", "likes": "点赞数", "views": "播放数",
  ] }
}
