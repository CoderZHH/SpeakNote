import SwiftUI

/// Shared title editor for tasks, notes and collections. Commit on submit/blur, never on every keystroke.
struct InlineItemText: View {
  let value: String
  var placeholder: String = "内容"
  let inlineDone: Bool
  let identifier: String
  private let pasteImages: (([NSItemProvider]) -> Void)?
  let save: @MainActor (String) async throws -> Void
  @Environment(AppSession.self) private var session
  @State private var text: String
  @State private var saving = false
  @State private var editing = false
  @FocusState private var focused: Bool
  #if os(iOS)
    @State private var nativeRemarkFocused = false
  #endif
  init(
    _ value: String, placeholder: String = "内容", inlineDone: Bool = false,
    identifier: String = "",
    pasteImages: (([NSItemProvider]) -> Void)? = nil,
    save: @escaping @MainActor (String) async throws -> Void
  ) {
    self.value = value
    self.placeholder = placeholder
    self.inlineDone = inlineDone
    self.identifier = identifier
    self.pasteImages = pasteImages
    self.save = save
    _text = State(initialValue: value)
  }
  var body: some View {
    Group {
      if editing {
        HStack(alignment: .top, spacing: WorkbenchDesign.Space.small) {
          input.disabled(saving).task { setEditingFocus(true) }
          #if os(iOS)
            if inlineDone {
              Button("完成", action: finishEditing).buttonStyle(.borderless)
                .foregroundStyle(saving ? Color.secondary : Color.accentColor)
                .frame(minWidth: WorkbenchDesign.rowMinimum, minHeight: WorkbenchDesign.rowMinimum)
                .disabled(saving).accessibilityIdentifier("item.remark.done")
            }
          #endif
        }
      } else {
        Button {
          text = value
          editing = true
        } label: {
          Text(value.isEmpty ? placeholder : value)
            .foregroundStyle(value.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("轻点编辑")
          .accessibilityIdentifier(identifier, isEnabled: !identifier.isEmpty)
      }
    }
    .onChange(of: value) { _, value in if !editing && !saving { text = value } }
    #if os(macOS)
      .onDisappear {
        // Dismissing the detail sheet can remove the field before focus changes are delivered.
        if inlineDone && editing { commit() }
      }
    #endif
  }
  @ViewBuilder private var input: some View {
    #if os(iOS)
      if let pasteImages {
        RemarkTextInput(
          text: $text, focused: $nativeRemarkFocused,
          placeholder: placeholder, identifier: identifier, pasteImages: pasteImages, onEnd: commit
        ).overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text(placeholder).font(.subheadline).foregroundStyle(.secondary)
              .allowsHitTesting(false).accessibilityHidden(true)
          }
        }
      } else {
        textField
      }
    #else
      textField.remarkImagePaste(perform: pasteImages)
    #endif
  }
  private var textField: some View {
    TextField(placeholder, text: $text, axis: .vertical).textFieldStyle(.plain)
      .lineLimit(1...20).foregroundStyle(.primary).focused($focused)
      .accessibilityIdentifier(identifier, isEnabled: !identifier.isEmpty)
      .workspaceKeyboardDone(when: focused && !inlineDone, done: finishEditing)
      .onSubmit { finishEditing() }
      .onChange(of: focused) { _, focused in if !focused { commit() } }
  }
  private func finishEditing() {
    #if os(iOS)
      if pasteImages != nil && nativeRemarkFocused {
        setEditingFocus(false)
        return  // The native editor publishes its final text when editing ends.
      }
    #endif
    setEditingFocus(false)
    commit()
  }
  private func setEditingFocus(_ active: Bool) {
    #if os(iOS)
      if pasteImages != nil {
        nativeRemarkFocused = active
        return
      }
    #endif
    focused = active
  }
  private func commit() {
    guard !saving else { return }
    guard text != value else {
      editing = false
      return
    }
    let submitted = text
    saving = true
    Task {
      defer { saving = false }
      do {
        try await save(submitted)
        editing = false
        session.scheduleSync()
      } catch {
        session.error = error.localizedDescription
        setEditingFocus(true)
      }
    }
  }
}
struct ItemRow: View {
  let item: WorkspaceItem
  var showsAssociation = true
  @Environment(AppSession.self) private var session
  @Environment(\.openCollection) private var openCollection
  @State private var remarks = false
  @State private var association = false
  @State private var schedule = false
  @State private var deletion = false
  @State private var actions = false
  @State private var pendingAction: ItemAction?
  var isTask: Bool { item.entity == .tasks }
  private var hasRemarks: Bool {
    !item[isTask ? .notes : .remark].string.isEmpty
      || session.workspace?.snapshot[.attachments].contains {
        $0.fields[isTask ? "task_id" : "note_id"] == .string(item.id)
      } == true
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        if isTask {
          Button {
            update([.status: .string(item.status == "done" ? "todo" : "done")])
          } label: {
            Image(systemName: item.status == "done" ? "checkmark.circle.fill" : "circle").font(
              .system(size: 17, weight: .light)
            ).foregroundStyle(item.status == "done" ? Color.accentColor : .secondary)
          }.buttonStyle(.plain).accessibilityLabel(item.status == "done" ? "恢复任务" : "完成任务")
        }
        VStack(alignment: .leading, spacing: 4) {
          InlineItemText(item.title) { text in
            _ = try await session.workspace?.perform(
              .update(item.entity, id: item.id, fields: [isTask ? .title : .content: .string(text)])
            )
          }.strikethrough(isTask && item.status == "done").frame(
            maxWidth: .infinity, alignment: .leading
          ).accessibilityIdentifier("item.title." + item.id)
          #if os(iOS)
            if showsAssociation { associationLabel }
          #endif
        }.frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
          if showsAssociation { associationLabel }
        #endif
        dateLabel
        Button(
          "备注",
          systemImage: hasRemarks ? "text.bubble.fill" : "text.bubble"
        ) { remarks.toggle() }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(
          remarks ? Color.accentColor : .secondary
        ).frame(width: 24, height: 28)
          .accessibilityIdentifier("item.remarks." + item.id)
        Button {
          actions = true
        } label: {
          Image(systemName: "ellipsis").font(.body.weight(.semibold))
            .frame(width: 28, height: 30)
            .foregroundStyle(importanceColor(item.importance))
            .background(
              item.importance > 1 ? importanceColor(item.importance).opacity(0.14) : .clear,
              in: .rect(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel("条目操作")
          .accessibilityValue(isTask ? "重要程度 \(item.importance)，共五级" : "")
          .accessibilityIdentifier("item.actions." + item.id)
          .popover(isPresented: $actions) {
            ItemActionPanel(item: item) { action in
              pendingAction = action
              actions = false
            }
            .presentationCompactAdaptation(.popover)
            .onDisappear { performPendingAction() }
          }
      }
      if remarks { ItemRemarks(item: item).padding(.leading, isTask ? 30 : 0) }
    }.padding(.vertical, 5)
      .sheet(isPresented: $association) { AssociationPicker(item: item) }
      .sheet(isPresented: $schedule) { ScheduleEditor(item: item) }
      .confirmationDialog("删除这条内容？", isPresented: $deletion, titleVisibility: .visible) {
        Button("删除", role: .destructive) {
          session.run {
            _ = try await session.workspace?.perform(.delete(item.entity, id: item.id))
          }
        }
      }
  }
  @ViewBuilder private var associationLabel: some View {
    if let linked = session.workspace?.snapshot.association(item) {
      Button {
        openCollection?(CollectionRoute(entity: linked.entity, id: linked.id))
      } label: {
        Label(
          linked.title,
          systemImage: linked.entity == .projects
            ? "folder" : linked.entity == .courses ? "graduationcap" : "book"
        )
        .font(.caption).lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 5))
      }.buttonStyle(.plain).foregroundStyle(.secondary)
        .disabled(openCollection == nil)
        .accessibilityIdentifier("item.association." + item.id)
        #if os(macOS)
          .frame(maxWidth: 160, alignment: .trailing)
        #else
          .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
  }
  @ViewBuilder private var dateLabel: some View {
    if !item[.dueDate].isNull && !item[.dueDate].string.isEmpty {
      let due = item[.dueDate].string
      Text(String(due.suffix(5)).replacingOccurrences(of: "-", with: "/"))
        .font(.caption.monospacedDigit())
        .foregroundStyle(
          due < Clock.day() && item.status == "todo"
            ? Color.red : (isTask ? importanceColor(item.importance) : .secondary)
        )
        .fixedSize().help("截止日期：" + due)
    }
  }
  private func performPendingAction() {
    guard let action = pendingAction else { return }
    pendingAction = nil
    switch action {
    case .focus:
      session.run { _ = try await session.workspace?.perform(.startFocus(taskID: item.id)) }
    case .move:
      update([.plannedDate: item[.plannedDate].isNull ? .string(Clock.day()) : .null])
    case .restore: update([.status: .string("todo"), .plannedDate: .string(Clock.day())])
    case .schedule: schedule = true
    case .importance(let level):
      if level != item.importance { update([.importance: .integer(Int64(level))]) }
    case .convert:
      session.run {
        _ = try await session.workspace?.perform(
          .convertNote(id: item.id, plannedDate: Clock.day()))
      }
    case .associate: association = true
    case .abandon: update([.status: .string("abandoned")])
    case .archive: update([.status: .string(item.status == "archived" ? "inbox" : "archived")])
    case .delete: deletion = true
    }
  }
  func update(_ fields: [ItemField: JSONValue]) {
    session.run {
      _ = try await session.workspace?.perform(.update(item.entity, id: item.id, fields: fields))
    }
  }
}
struct ItemRemarks: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  @State private var pastingImage = false
  @State private var pendingImages: [NSItemProvider] = []
  var field: ItemField {
    item.entity == .tasks ? .notes : item.entity == .notes ? .remark : .description
  }
  var owner: MediaOwner {
    switch item.entity {
    case .tasks: .task(item.id)
    case .notes: .note(item.id)
    case .projects: .project(item.id)
    case .courses: .course(item.id)
    default: .learning(item.id)
    }
  }
  var attachments: [WorkspaceItem] {
    session.workspace?.snapshot[.attachments].filter { $0.fields[owner.field] == .string(owner.id) }
      ?? []
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      InlineItemText(
        item[field].string, placeholder: "添加备注…", inlineDone: true,
        identifier: "item.remark.text." + item.id, pasteImages: pasteImages
      ) { text in
        guard let store = session.workspace else { throw WorkBenchError("工作区未就绪") }
        _ = try await store.perform(
          .update(item.entity, id: item.id, fields: [field: .string(text)]))
      }.font(.subheadline).foregroundStyle(item[field].string.isEmpty ? .secondary : .primary)
      ItemAttachmentPreviews(attachments: attachments)
      HStack(spacing: WorkbenchDesign.Space.medium) {
        MediaPicker(title: "添加附件", imagesOnly: false, onData: importAttachment)
          .accessibilityIdentifier("item.attachments." + owner.id)
        if pastingImage { ProgressView().controlSize(.small).accessibilityLabel("正在粘贴图片") }
      }.font(.subheadline)
    }
  }
  private func importAttachment(_ data: Data, _ name: String) async throws {
    guard let store = session.workspace else { throw WorkBenchError("工作区未就绪") }
    _ = try await store.database.importAttachment(data: data, name: name, owner: owner)
    try await store.refresh()
    session.scheduleSync()
  }
  private func pasteImages(_ providers: [NSItemProvider]) {
    guard !providers.isEmpty else { return }
    pendingImages.append(contentsOf: providers)
    guard !pastingImage else { return }
    pastingImage = true
    Task {
      defer { pastingImage = false }
      while !pendingImages.isEmpty {
        let provider = pendingImages.removeFirst()
        do {
          if let image = try await RemarkImagePaste.load(provider) {
            try await importAttachment(image.data, image.name)
          }
        } catch { session.error = error.localizedDescription }
      }
    }
  }
}

struct ItemAttachmentPreviews: View {
  let attachments: [WorkspaceItem]
  @Environment(AppSession.self) private var session
  @State private var preview: URL?

  var body: some View {
    if !attachments.isEmpty,
      let directory = session.location?.directory.appendingPathComponent("attachments")
    {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(attachments) { item in
            let attachment = MediaAttachment(fields: item.fields)
            Button {
              preview = directory.appendingPathComponent(attachment.fileKey)
            } label: {
              AttachmentThumbnail(attachment: attachment, directory: directory).frame(
                width: 64, height: 64
              ).clipped().clipShape(.rect(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("查看附件 " + attachment.name).contextMenu {
              Button("移除附件", systemImage: "trash", role: .destructive) {
                session.run {
                  _ = try await session.workspace?.perform(
                    .delete(.attachments, id: attachment.id))
                }
              }
            }
          }
        }
      }.scrollIndicators(.hidden).quickLookPreview($preview)
    }
  }
}
struct AssociationPicker: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  var body: some View {
    AssociationSelectionPicker(selected: session.workspace?.snapshot.association(item)) { linked in
      guard let store = session.workspace else { throw WorkBenchError("工作区未就绪") }
      _ = try await store.perform(
        .update(
          item.entity, id: item.id,
          fields: try itemAssociationFields(linked)))
      session.scheduleSync()
    }
  }
}

/// Selecting for a new item changes local form state only; existing items supply a store action.
struct AssociationSelectionPicker: View {
  var selected: WorkspaceItem?
  let select: @MainActor (WorkspaceItem?) async throws -> Void
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var saving = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      WorkspaceList {
        Button("不关联") { choose(nil) }
        ForEach([WorkspaceEntity.projects, .learning, .courses], id: \.self) { entity in
          Section(entity == .projects ? "项目" : entity == .learning ? "学习" : "课程") {
            ForEach(
              (session.workspace?.snapshot[entity] ?? []).filter {
                $0.status != "done"
                  && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
              }
            ) { linked in
              Button {
                choose(linked)
              } label: {
                HStack {
                  Text(linked.title).foregroundStyle(.primary)
                  Spacer()
                  if selected?.id == linked.id && selected?.entity == linked.entity {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
      }.disabled(saving).searchable(text: $search, prompt: "搜索关联内容").navigationTitle("关联")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }.disabled(saving)
          }
        }
    }.interactiveDismissDisabled(saving)
      #if os(macOS)
        .frame(width: WorkbenchDesign.sheetWidth, height: WorkbenchDesign.SelectionLayout.height)
      #endif
  }
  private func choose(_ linked: WorkspaceItem?) {
    guard !saving else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        try await select(linked)
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}

struct ScheduleEditor: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  var body: some View {
    TaskScheduleEditor(value: TaskScheduleValues(item: item)) { value in
      guard let store = session.workspace else { throw WorkBenchError("工作区未就绪") }
      let fields = try value.fields()
      if value.needsReminderPermission { try await session.requestTaskReminderAuthorization() }
      _ = try await store.perform(.update(.tasks, id: item.id, fields: fields))
      session.scheduleSync()
      if value.needsReminderPermission, let issue = session.taskReminderIssue {
        throw WorkBenchError("安排已保存，" + issue)
      }
    }
  }
}

struct TaskScheduleEditor: View {
  let save: @MainActor (TaskScheduleValues) async throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var value: TaskScheduleValues
  @State private var saving = false
  @State private var error: String?
  init(
    value: TaskScheduleValues,
    save: @escaping @MainActor (TaskScheduleValues) async throws -> Void
  ) {
    _value = State(initialValue: value)
    self.save = save
  }
  var body: some View {
    NavigationStack {
      Form {
        WorkspaceDateField(title: "日期", selection: $value.date)
        Toggle("具体时间", isOn: $value.timed).accessibilityIdentifier("schedule.timed")
        if value.timed {
          DatePicker("开始", selection: $value.start, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("schedule.start")
          DatePicker("结束", selection: $value.end, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("schedule.end")
        }
        Toggle("提醒", isOn: $value.reminder).disabled(!value.timed && value.reminderAt == nil)
          .accessibilityIdentifier("schedule.reminder")
          .help("默认在计划开始时间提醒")
        if let reminderAt = value.reminderAt, value.reminder {
          Text("提醒时间：\(Clock.day(reminderAt)) \(TaskScheduleValues.time(reminderAt))")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        if let error { Text(error).font(.subheadline).foregroundStyle(.red) }
      }.environment(\.timeZone, Clock.calendar.timeZone).environment(\.calendar, Clock.calendar)
        .disabled(saving).workspaceSheetForm(height: 340).navigationTitle("安排时间").toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }.disabled(saving).accessibilityIdentifier("schedule.cancel")
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成", action: commit).disabled(saving).accessibilityIdentifier(
              "schedule.complete")
          }
        }
    }.interactiveDismissDisabled(saving)
      .onChange(of: value.timed) { _, enabled in if !enabled && value.reminderAt == nil { value.reminder = false } }
  }
  private func commit() {
    guard !saving else { return }
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        _ = try value.fields()
        try await save(value)
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}
struct NewItemForm: View {
  let entity: WorkspaceEntity
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var details = ""
  @State private var linked: WorkspaceItem?
  @State private var importance = 1
  @State private var schedule = TaskScheduleValues()
  @State private var linking = false
  @State private var scheduling = false
  @State private var saving = false
  @State private var error: String?
  @State private var entryID = UUID().uuidString.lowercased()
  @State private var pendingAttachments: [StagedEntryAttachment] = []
  @State private var attachmentStaging = EntryAttachmentStaging()
  @State private var importing = false
  @FocusState private var titleFocused: Bool
  init(entity: WorkspaceEntity, association: WorkspaceItem? = nil) {
    self.entity = entity
    _linked = State(initialValue: association)
  }
  private var heading: String {
    entity == .tasks ? "新建任务" : entity == .notes ? "随手记" : entity == .projects ? "新建项目" : "新建学习"
  }
  private var prompt: String {
    entity == .tasks
      ? "接下来要做什么？" : entity == .notes ? "先记下来…" : entity == .projects ? "项目名称" : "想学习什么？"
  }
  var body: some View {
    WorkspaceEntrySheet(
      title: heading, confirmTitle: entity == .notes ? "保存" : "添加", saving: saving || importing,
      canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      cancel: {
        Task {
          await attachmentStaging.discard()
          dismiss()
        }
      }, save: save
    ) {
      Group {
        TextField(prompt, text: $title, axis: .vertical).lineLimit(1...8)
          .font(.title3).focused($titleFocused).labelsHidden()
          .workspaceInput(focused: titleFocused).accessibilityIdentifier("entry.title")
        if [.tasks, .projects, .learning].contains(entity) {
          TextField("添加备注（选填）", text: $details, axis: .vertical).lineLimit(1...6)
            .labelsHidden().workspaceInput().accessibilityIdentifier("entry.details")
        }
        if entity == .tasks || entity == .notes {
          VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
            ForEach(pendingAttachments) { item in
              HStack {
                Label(item.name, systemImage: "paperclip").lineLimit(1)
                Spacer()
                Button("移除附件", systemImage: "xmark.circle.fill") {
                  Task {
                    try? await attachmentStaging.remove(item)
                    pendingAttachments.removeAll { $0.id == item.id }
                  }
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
              }.font(.subheadline)
            }
            MediaPicker(title: "添加附件", imagesOnly: false, importing: $importing) { data, name in
              try require(pendingAttachments.count < 10, "最多添加10个附件")
              let item = try await attachmentStaging.add(data: data, name: name)
              pendingAttachments.append(item)
            }.font(.subheadline).accessibilityIdentifier("entry.attachments")
          }
        }
        if [.tasks, .notes].contains(entity) {
          VStack(spacing: 0) {
            Button {
              titleFocused = false
              linking = true
            } label: {
              propertyRow("关联", symbol: "link", value: linked?.title ?? "不关联")
            }.buttonStyle(.plain).accessibilityIdentifier("entry.association")
            if entity == .tasks {
              Divider()
              HStack {
                Label("重要程度", systemImage: "flag").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: WorkbenchDesign.Space.medium) {
                  TaskImportanceChoices(selected: importance) { importance = $0 }
                }.font(.title3).buttonStyle(.borderless)
              }.frame(minHeight: WorkbenchDesign.controlHeight)
              Divider()
              Button {
                titleFocused = false
                scheduling = true
              } label: {
                HStack(spacing: WorkbenchDesign.Space.small) {
                  propertyRow("安排", symbol: "calendar", value: schedule.summary)
                  if schedule.needsReminderPermission {
                    Image(systemName: "bell.fill").foregroundStyle(.tint)
                  }
                }
              }.buttonStyle(.plain).accessibilityIdentifier("entry.schedule")
            }
          }.font(.subheadline)
        }
      }.disabled(saving)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.onAppear { titleFocused = true }
      .sheet(isPresented: $linking) {
        AssociationSelectionPicker(selected: linked) { linked = $0 }
      }
      .sheet(isPresented: $scheduling) {
        TaskScheduleEditor(value: schedule) { schedule = $0 }
      }
  }
  private func propertyRow(_ title: String, symbol: String, value: String) -> some View {
    HStack(spacing: WorkbenchDesign.Space.small) {
      Label(title, systemImage: symbol).foregroundStyle(.secondary)
      Spacer(minLength: WorkbenchDesign.Space.medium)
      Text(value).foregroundStyle(.primary).lineLimit(1)
      Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
    }.frame(minHeight: WorkbenchDesign.controlHeight).contentShape(Rectangle())
  }
  private func save() {
    guard !saving, !importing, let store = session.workspace,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        let fields: [ItemField: JSONValue]
        if entity == .tasks {
          let values = TaskEntryValues(
            title: title, notes: details, importance: importance,
            association: linked, schedule: schedule)
          fields = try values.fields()
          if schedule.needsReminderPermission {
            try await session.requestTaskReminderAuthorization()
          }
        } else {
          var values: [ItemField: JSONValue] = [
            entity == .notes ? .content : .title: .string(title)
          ]
          if [.projects, .learning].contains(entity) { values[.description] = .string(details) }
          if entity == .notes { values.merge(try itemAssociationFields(linked)) { _, v in v } }
          fields = values
        }
        try await store.database.saveEntry(
          entity: entity, id: entryID, fields: fields,
          attachments: pendingAttachments)
        try await store.refresh()
        session.scheduleSync()
        if entity == .tasks, schedule.needsReminderPermission, let issue = session.taskReminderIssue
        {
          session.error = "任务已添加，" + issue
        }
        await attachmentStaging.discard()
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}
