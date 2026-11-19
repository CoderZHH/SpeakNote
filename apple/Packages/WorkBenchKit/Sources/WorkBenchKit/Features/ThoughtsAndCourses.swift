import SwiftUI
#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

struct ThoughtRoute: Hashable, Identifiable {
  let id: String
  var initialTags: [String]? = nil
}

private func thoughtBodyExcerpt(_ content: String) -> String {
  let lines = content.components(separatedBy: .newlines)
  guard lines.count > 1 else { return "" }
  return lines.dropFirst()
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
    .prefix(3)
    .joined(separator: " ")
}

private func thoughtCharCount(_ content: String) -> Int {
  content.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
}

struct ThoughtSummary: View {
  let item: WorkspaceItem
  var liveText: String? = nil
  var liveTags: [String]? = nil

  private var rawContent: String { liveText ?? item[.content].string }
  private var resolvedTags: [String] { liveTags ?? thoughtTags(item) }

  var body: some View {
    let title = thoughtTitle(rawContent)
    let excerpt = thoughtBodyExcerpt(rawContent)
    let shortDate = String(item[.day].string.suffix(5)).replacingOccurrences(of: "-", with: "/")

    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title)
          .font(.system(size: 14.5, weight: .medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(shortDate)
          .font(.system(size: 11.5, design: .rounded).monospacedDigit())
          .foregroundStyle(.tertiary)
          .fixedSize()
      }

      if !excerpt.isEmpty {
        Text(excerpt)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .lineSpacing(2.5)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !resolvedTags.isEmpty {
        HStack(spacing: 5) {
          ForEach(resolvedTags.prefix(4), id: \.self) { tag in
            Text("#" + tag)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.primary.opacity(0.045), in: .capsule)
          }
        }
        .padding(.top, 1)
      }
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
  }
}

struct ThoughtsView: View {
  @Environment(AppSession.self) private var session
  @State private var tag = "全部"
  @State private var managingTags = false
  @State private var tagToRemove: String?
  @State private var thoughtToDelete: WorkspaceItem?
  @State private var search = ""
  @State private var selected: String?
  @State private var hoveredID: String?
  @State private var composition: ThoughtRoute?
  @State private var newRoute: ThoughtRoute?

  private var allThoughts: [WorkspaceItem] {
    let saved = session.workspace?.snapshot[.reflections] ?? []
    let ids = Set(saved.map(\.id))
    return saved + session.thoughtEditing.pendingItems.filter { !ids.contains($0.id) }
  }

  private func effectiveText(for item: WorkspaceItem) -> String {
    session.thoughtEditing.buffers[item.id]?.text ?? item[.content].string
  }

  private func effectiveTags(for item: WorkspaceItem) -> [String] {
    session.thoughtEditing.buffers[item.id]?.tags ?? thoughtTags(item)
  }

  private var tags: [String] {
    ["全部"] + Set(allThoughts.flatMap { effectiveTags(for: $0) }).subtracting(["全部"]).sorted()
  }

  private var thoughts: [WorkspaceItem] {
    allThoughts.filter { item in
      let itemTags = effectiveTags(for: item)
      let content = effectiveText(for: item)
      let matchesTag = (tag == "全部" || itemTags.contains(tag))
      let matchesSearch =
        search.isEmpty
        || content.localizedCaseInsensitiveContains(search)
        || itemTags.contains { $0.localizedCaseInsensitiveContains(search) }
      return matchesTag && matchesSearch
    }.sorted {
      let d0 = session.thoughtEditing.buffers[$0.id]?.day ?? $0[.day].string
      let d1 = session.thoughtEditing.buffers[$1.id]?.day ?? $1[.day].string
      return (d0, $0.createdAt, $0.id) > (d1, $1.createdAt, $1.id)
    }
  }

  var body: some View {
    Group {
      #if os(macOS)
        GeometryReader { geometry in
          if geometry.size.width >= 720 {
            HStack(spacing: 0) {
              browser(selection: true)
                .frame(width: min(310, max(268, geometry.size.width * 0.30)))

              Rectangle()
                .fill(WorkbenchDesign.line)
                .frame(width: 1)

              Group {
                if let selected, let route = editorRoute(selected) {
                  ThoughtEditor(id: route.id, initialTags: route.initialTags)
                    .id(route.id)
                } else {
                  EmptyState(
                    title: allThoughts.isEmpty ? "记录你的第一篇思考" : "选择一篇思考",
                    symbol: "square.and.pencil",
                    detail: "首行自动作为标题，支持人文、书卷衬线与圆体排版，输入即自动保存。"
                  )
                }
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar { newButton(inline: true) }
          } else {
            browser(selection: false)
              .toolbar { newButton(inline: false) }
          }
        }
      #else
        browser(selection: false).phoneCreateAction("记一点", identifier: "thought.new") {
          beginNew(inline: false)
        }
      #endif
    }
    .alert(
      "删除标签？",
      isPresented: Binding(
        get: { tagToRemove != nil }, set: { if !$0 { tagToRemove = nil } }
      ),
      presenting: tagToRemove
    ) { name in
      Button("删除", role: .destructive) {
        session.run {
          guard let store = session.workspace else { return }
          try await session.thoughtEditing.removeTag(name, from: store)
          if tag == name { tag = "全部" }
        }
      }
      Button("取消", role: .cancel) {}
    } message: { name in
      Text("「\(name)」将从所有思考中移除，正文会保留。")
    }
    .confirmationDialog(
      "删除这篇思考？",
      isPresented: Binding(
        get: { thoughtToDelete != nil }, set: { if !$0 { thoughtToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let target = thoughtToDelete {
        Button("删除", role: .destructive) {
          let targetID = target.id
          thoughtToDelete = nil
          session.run {
            guard let store = session.workspace else { return }
            await session.thoughtEditing.flush(id: targetID, store: store)
            if store.snapshot.item(.reflections, targetID) != nil {
              _ = try await store.perform(.delete(.reflections, id: targetID))
            }
            session.thoughtEditing.remove(targetID)
            if selected == targetID { selected = thoughts.first { $0.id != targetID }?.id }
          }
        }
      }
    }
    .onChange(of: tags) { _, available in
      if !available.contains(tag) { tag = "全部" }
    }
    .navigationDestination(for: ThoughtRoute.self) {
      ThoughtEditor(id: $0.id, initialTags: $0.initialTags)
    }
    .navigationDestination(item: $newRoute) {
      ThoughtEditor(id: $0.id, initialTags: $0.initialTags)
    }
    #if os(macOS)
      .onChange(of: thoughts.map(\.id), initial: true) { _, ids in
        if selected == nil {
          selected = ids.first
        } else if let selected, editorRoute(selected) == nil {
          self.selected = ids.first
        }
      }
    #endif
  }

  @ToolbarContentBuilder private func newButton(inline: Bool) -> some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button("新建思考", systemImage: "plus") {
        beginNew(inline: inline)
      }.accessibilityIdentifier("thought.new")
    }
  }

  private func beginNew(inline: Bool) {
    let route = ThoughtRoute(
      id: UUID().uuidString.lowercased(),
      initialTags: tag == "全部" ? [] : [tag])
    session.thoughtEditing.beginNew(id: route.id, tags: route.initialTags ?? [])
    if inline {
      composition = route
      selected = route.id
    } else {
      newRoute = route
    }
  }

  private func editorRoute(_ id: String) -> ThoughtRoute? {
    if composition?.id == id { return composition }
    if allThoughts.contains(where: { $0.id == id }) { return ThoughtRoute(id: id) }
    return nil
  }

  private var tagManagement: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      Text("管理标签").font(.system(size: 14, weight: .medium))
      if tags.count == 1 {
        Text("还没有标签").font(.subheadline).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
            ForEach(tags.dropFirst(), id: \.self) { name in
              HStack {
                Text("#" + name).font(.subheadline)
                Spacer()
                Button("删除标签", systemImage: "trash", role: .destructive) {
                  managingTags = false
                  tagToRemove = name
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("删除标签 " + name)
              }
              .padding(.vertical, 2)
            }
          }
        }.frame(maxHeight: WorkbenchDesign.ThoughtLayout.tagListHeight)
      }
    }
    .padding(WorkbenchDesign.Space.section)
    .frame(width: WorkbenchDesign.ThoughtLayout.tagPickerWidth)
  }

  private func browser(selection: Bool) -> some View {
    VStack(spacing: 0) {
      WorkspaceMasterHeader(prompt: "搜索思考", search: $search) {
        HStack(spacing: WorkbenchDesign.Space.small) {
          ScrollView(.horizontal) {
            WorkspaceFilters(values: tags, selection: $tag, title: { $0 == "全部" ? "全部" : "#" + $0 })
          }.scrollIndicators(.hidden)
          if tags.count > 1 {
            Button("管理标签", systemImage: "slider.horizontal.3") { managingTags = true }
              .labelStyle(.iconOnly)
              .buttonStyle(.plain)
              .font(.caption)
              .foregroundStyle(.secondary)
              .help("管理标签")
              .popover(isPresented: $managingTags) { tagManagement }
          }
        }
      }

      if thoughts.isEmpty {
        EmptyState(
          title: !search.isEmpty ? "没有匹配的思考" : "暂无思考记录",
          symbol: !search.isEmpty ? "magnifyingglass" : "text.bubble",
          detail: !search.isEmpty ? "换个关键词试试" : "点击右上角「+」记录一段深度想法"
        )
      } else {
        ScrollView {
          LazyVStack(spacing: selection ? 4 : 0) {
            ForEach(thoughts) { item in
              if selection {
                desktopSummaryCard(item)
              } else {
                VStack(spacing: 0) {
                  NavigationLink(value: ThoughtRoute(id: item.id)) {
                    ThoughtSummary(
                      item: item,
                      liveText: effectiveText(for: item),
                      liveTags: effectiveTags(for: item)
                    )
                    .padding(.vertical, 4)
                  }
                  .buttonStyle(.plain)
                  Rectangle().fill(WorkbenchDesign.line).frame(height: 0.5)
                }
              }
            }
          }
          .padding(.horizontal, selection ? 10 : WorkbenchDesign.masterInset)
          .padding(.bottom, WorkbenchDesign.Space.section)
        }
      }
    }
    .background(WorkbenchDesign.canvas)
  }

  private func desktopSummaryCard(_ item: WorkspaceItem) -> some View {
    let isSelected = selected == item.id
    let isHovered = hoveredID == item.id
    return Button {
      selected = item.id
    } label: {
      ThoughtSummary(
        item: item,
        liveText: effectiveText(for: item),
        liveTags: effectiveTags(for: item)
      )
      .padding(.horizontal, 11)
      .padding(.vertical, 4)
      .background(
        isSelected
          ? WorkbenchDesign.selectionBackground
          : (isHovered ? Color.primary.opacity(0.035) : .clear),
        in: .rect(cornerRadius: 10, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onHover { hovering in
        hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
      }
    #endif
    .contextMenu {
      Button("复制全文", systemImage: "doc.on.doc") {
        copyPlainText(effectiveText(for: item))
      }
      Divider()
      Button("删除思考…", systemImage: "trash", role: .destructive) {
        thoughtToDelete = item
      }
    }
  }
}

private func copyPlainText(_ string: String) {
  #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  #elseif os(iOS)
    UIPasteboard.general.string = string
  #endif
}

/// The Today entry uses the same full editor. Empty dismissal leaves no record.
struct NewThoughtView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var id = UUID().uuidString.lowercased()
  @State private var closing = false
  var body: some View {
    NavigationStack {
      ThoughtEditor(id: id, initialTags: []).toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            guard !closing, let store = session.workspace else { return }
            closing = true
            Task {
              await session.thoughtEditing.flush(id: id, store: store)
              closing = false
              if session.thoughtEditing.buffers[id]?.error == nil { dismiss() }
            }
          }.disabled(closing)
        }
      }
    }
    #if os(macOS)
      .frame(
        minWidth: WorkbenchDesign.ThoughtLayout.editorWidth,
        minHeight: WorkbenchDesign.ThoughtLayout.editorHeight)
    #endif
  }
}

struct ThoughtEditor: View {
  let id: String
  var initialTags: [String]? = nil
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @AppStorage("thoughtFontStyle") private var fontStyleRaw = ThoughtFontStyle.sans.rawValue
  @AppStorage("thoughtFontScale") private var fontScaleRaw = ThoughtFontScale.standard.rawValue
  @State private var deletion = false
  @State private var deleting = false
  @State private var focused = false
  @State private var reviewing = false
  @State private var showingTypography = false
  @State private var showingDatePicker = false
  @State private var copiedToast = false

  private var item: WorkspaceItem? { session.workspace?.snapshot.item(.reflections, id) }
  private var buffer: ThoughtEditing.Buffer? { session.thoughtEditing.buffers[id] }

  private var fontStyle: ThoughtFontStyle {
    ThoughtFontStyle(rawValue: fontStyleRaw) ?? .sans
  }

  private var fontScale: ThoughtFontScale {
    ThoughtFontScale(rawValue: fontScaleRaw) ?? .standard
  }

  private var currentText: String {
    buffer?.text ?? item?[.content].string ?? ""
  }

  private var currentDayString: String {
    let raw = buffer?.day ?? item?[.day].string ?? ""
    return raw.isEmpty ? Clock.day() : raw
  }

  private var currentDate: Date {
    (try? Clock.parse(currentDayString + "T12:00:00+08:00")) ?? .now
  }

  var body: some View {
    Group {
      if let store = session.workspace, item != nil || buffer != nil || initialTags != nil {
        VStack(spacing: 0) {
          editorialTopBar(store: store)
            .padding(.horizontal, WorkbenchDesign.pageInset)
            .padding(.top, 16)
            .padding(.bottom, 6)

          ThoughtTagPicker(
            tags: buffer?.tags ?? item.map(thoughtTags) ?? initialTags ?? [],
            suggestions: allTags
          ) { tags in
            try session.thoughtEditing.stageTags(id: id, tags: tags, store: store)
          }
          .padding(.horizontal, WorkbenchDesign.pageInset)
          .padding(.bottom, 8)

          if let error = buffer?.error {
            HStack(alignment: .top, spacing: WorkbenchDesign.Space.small) {
              Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
              Text(error).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              if buffer?.conflict != nil {
                Button("核对版本") { reviewing = true }.buttonStyle(.borderless)
              } else {
                Button("重试") {
                  Task { await session.thoughtEditing.flush(id: id, store: store) }
                }.buttonStyle(.borderless)
              }
            }
            .padding(.horizontal, WorkbenchDesign.pageInset)
            .padding(.vertical, WorkbenchDesign.Space.small)
            .accessibilityIdentifier("thought.save.error")
          }

          ZStack(alignment: .topLeading) {
            ThoughtTextEditor(
              text: Binding(
                get: { currentText },
                set: { session.thoughtEditing.stage(id: id, text: $0, store: store) }
              ),
              focused: $focused,
              fontStyle: fontStyle,
              fontScale: fontScale
            )
            .accessibilityIdentifier("thought.content")

            if currentText.isEmpty {
              Text("写下此刻的想法…")
                .font(fontStyle.placeholderTitleFont(scale: fontScale))
                .foregroundStyle(.quaternary)
                .padding(.top, 10)
                .allowsHitTesting(false)
            }
          }
          .padding(.horizontal, WorkbenchDesign.pageInset)
          .padding(.bottom, WorkbenchDesign.pageInset)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchDesign.canvas)
        .disabled(deleting)
      } else {
        EmptyState(title: "思考已删除", symbol: "text.bubble", detail: "可从左侧选择其他思考或新建一篇。")
      }
    }
    .navigationTitle("")
    .phoneDetailNavigation()
    .onAppear {
      if let item {
        session.thoughtEditing.begin(item)
      } else if let initialTags {
        session.thoughtEditing.beginNew(id: id, tags: initialTags)
      }
      if initialTags != nil { focused = true }
    }
    .onChange(of: item) { _, value in
      if let value { session.thoughtEditing.begin(value) }
    }
    .onChange(of: buffer?.conflict) { _, version in
      if version == nil { reviewing = false }
    }
    .sheet(isPresented: $reviewing) {
      if let store = session.workspace, let buffer, let saved = buffer.conflict {
        ThoughtConflictReview(
          saved: saved, draft: .init(text: buffer.text, tags: buffer.tags),
          error: buffer.error
        ) { version, keepDraft in
          await session.thoughtEditing.resolve(
            id: id, reviewed: version, keepDraft: keepDraft, store: store)
        }
      }
    }
    .onDisappear {
      guard let store = session.workspace else { return }
      Task {
        await session.thoughtEditing.flush(id: id, store: store)
        if let buffer = session.thoughtEditing.buffers[id], !buffer.persisted,
          buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          session.thoughtEditing.remove(id)
        }
      }
    }
    .toolbar {
      #if os(iOS)
        if focused {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { focused = false }.accessibilityIdentifier("keyboard.done")
          }
        }
      #endif
    }
    .confirmationDialog("删除这篇思考？", isPresented: $deletion) {
      Button("删除", role: .destructive) {
        guard let store = session.workspace else { return }
        deleting = true
        session.run {
          defer { deleting = false }
          await session.thoughtEditing.flush(id: id, store: store)
          if store.snapshot.item(.reflections, id) != nil {
            _ = try await store.perform(.delete(.reflections, id: id))
          }
          session.thoughtEditing.remove(id)
          dismiss()
        }
      }
    }
  }

  private func editorialTopBar(store: WorkspaceStore) -> some View {
    let chars = thoughtCharCount(currentText)
    return HStack(spacing: 8) {
      Button {
        showingDatePicker.toggle()
      } label: {
        Text(currentDate, format: .dateTime.year().month().day().weekday(.abbreviated))
          .font(.system(size: 12, design: .rounded))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("修改这篇思考的日期")
      .popover(isPresented: $showingDatePicker) {
        DatePicker(
          "思考日期",
          selection: Binding(
            get: { currentDate },
            set: { picked in
              session.thoughtEditing.stageDay(id: id, day: Clock.day(picked), store: store)
              showingDatePicker = false
            }
          ),
          displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .padding(10)
        .frame(width: 280)
      }

      if chars > 0 {
        Text("·")
          .font(.caption)
          .foregroundStyle(.quaternary)
        Text("\(chars) 字")
          .font(.system(size: 12, design: .rounded).monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      if buffer?.saving == true {
        Text("保存中…")
          .font(.system(size: 11))
          .foregroundStyle(.quaternary)
      } else if copiedToast {
        Text("已复制")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.green)
      }

      Spacer(minLength: 0)

      Button {
        showingTypography.toggle()
      } label: {
        Text("Aa")
          .font(.system(size: 13, weight: .medium, design: .serif))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 26)
          .background(
            showingTypography ? Color.primary.opacity(0.07) : .clear,
            in: .rect(cornerRadius: 6, style: .continuous)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("排版字体与字号")
      .popover(isPresented: $showingTypography) {
        typographyPopover
      }

      if item != nil || !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        WorkspaceMoreMenu(title: "思考操作") {
          Button("复制全文", systemImage: "doc.on.doc") {
            copyPlainText(currentText)
            copiedToast = true
            Task {
              try? await Task.sleep(for: .seconds(1.2))
              copiedToast = false
            }
          }
          if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("将标题加入今日待办", systemImage: "checkmark.circle") {
              let taskTitle = thoughtTitle(currentText)
              session.run {
                _ = try await store.perform(
                  .create(
                    .tasks,
                    fields: [
                      .title: .string(taskTitle),
                      .notes: .string(currentText),
                      .plannedDate: .string(Clock.day()),
                    ]))
              }
            }
          }
          Divider()
          Button("删除这篇思考…", systemImage: "trash", role: .destructive) {
            deletion = true
          }
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  private var typographyPopover: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text("字体风格")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 6) {
          ForEach(ThoughtFontStyle.allCases) { option in
            let active = fontStyle == option
            Button {
              fontStyleRaw = option.rawValue
            } label: {
              VStack(spacing: 3) {
                Text("字")
                  .font(option.samplePreviewFont)
                Text(option.label)
                  .font(.system(size: 11))
              }
              .foregroundStyle(active ? Color.accentColor : .primary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
              .background(
                active ? Color.accentColor.opacity(0.12) : WorkbenchDesign.fieldBackground,
                in: .rect(cornerRadius: 8, style: .continuous)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("字号大小")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 6) {
          ForEach(ThoughtFontScale.allCases) { scale in
            let active = fontScale == scale
            Button {
              fontScaleRaw = scale.rawValue
            } label: {
              Text(scale.label)
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                  active ? Color.accentColor.opacity(0.12) : WorkbenchDesign.fieldBackground,
                  in: .rect(cornerRadius: 7, style: .continuous)
                )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(14)
    .frame(width: 236)
  }

  private var allTags: [String] {
    Array(
      Set(
        (session.workspace?.snapshot[.reflections] ?? []).flatMap { item in
          session.thoughtEditing.buffers[item.id]?.tags ?? thoughtTags(item)
        } + session.thoughtEditing.pendingItems.flatMap(thoughtTags))
    ).sorted()
  }
}

private struct ThoughtConflictReview: View {
  let saved: ThoughtContentVersion
  let draft: ThoughtContentVersion
  let error: String?
  let resolve: (ThoughtContentVersion, Bool) async -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var resolving = false

  var body: some View {
    WorkspaceEntrySheet(
      title: "核对思考版本", confirmTitle: "保存我的版本", saving: resolving, canSave: true,
      cancel: { dismiss() }, save: { choose(keepDraft: true) }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.section) {
          version("我的输入", draft)
          version("已保存版本", saved)
          if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: WorkbenchDesign.ThoughtLayout.tagListHeight)
      Button("使用已保存版本") { choose(keepDraft: false) }.disabled(resolving)
    }
  }

  private func version(_ title: String, _ version: ThoughtContentVersion) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      Text(title).font(.headline)
      Text(version.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if !version.tags.isEmpty {
        Text(version.tags.map { "#" + $0 }.joined(separator: " "))
          .font(.footnote).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).workspaceCard()
  }

  private func choose(keepDraft: Bool) {
    guard !resolving else { return }
    resolving = true
    Task {
      await resolve(saved, keepDraft)
      resolving = false
    }
  }
}

struct ThoughtTagPicker: View {
  let tags: [String]
  let suggestions: [String]
  let change: ([String]) throws -> Void
  @State private var showing = false
  @State private var newTag = ""
  @State private var error: String?
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ForEach(tags, id: \.self) { tag in
            Button {
              apply(tags.filter { $0 != tag })
            } label: {
              HStack(spacing: 3) {
                Text("#" + tag)
                Image(systemName: "xmark")
                  .font(.system(size: 8, weight: .bold))
              }
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3.5)
              .background(Color.primary.opacity(0.05), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除标签 " + tag)
          }

          Button {
            showing.toggle()
          } label: {
            HStack(spacing: 3) {
              Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
              Text(tags.isEmpty ? "标签" : "添加")
                .font(.system(size: 12))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.035), in: .capsule)
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("thought.tags")
          .popover(isPresented: $showing) { picker.presentationCompactAdaptation(.popover) }
        }
      }
      .scrollIndicators(.hidden)
    }
    .frame(minHeight: 28, alignment: .leading)
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      tagEntry
      if !suggestions.isEmpty || !tags.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Set(suggestions + tags)).sorted(), id: \.self) { tag in
              suggestion(tag)
            }
          }
        }.frame(maxHeight: WorkbenchDesign.ThoughtLayout.tagListHeight)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .padding(WorkbenchDesign.Space.section)
    .frame(width: WorkbenchDesign.ThoughtLayout.tagPickerWidth)
  }

  private var tagEntry: some View {
    WorkspaceComposerLayout {
      TextField("输入新标签，回车添加", text: $newTag).textFieldStyle(.plain).focused($focused)
        .workspaceInput(focused: focused).onSubmit { add() }
        .accessibilityIdentifier("thought.tag.input")
      Button("添加标签", systemImage: "plus") { add() }.labelStyle(.iconOnly)
        .buttonStyle(WorkspaceSubmitButtonStyle())
        .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("thought.tag.add")
    }
  }

  private func suggestion(_ tag: String) -> some View {
    Button {
      _ = apply(tags.contains(tag) ? tags.filter { $0 != tag } : tags + [tag])
    } label: {
      HStack {
        Text("#" + tag).font(.subheadline).foregroundStyle(.primary)
        Spacer()
        if tags.contains(tag) { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
      }
      .frame(minHeight: WorkbenchDesign.rowMinimum)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("标签 " + tag)
    .accessibilityAddTraits(tags.contains(tag) ? .isSelected : [])
  }

  private func add() {
    let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard !value.isEmpty else { return }
    if apply(tags.contains(value) ? tags : tags + [value]) {
      newTag = ""
      showing = false
    }
  }

  @discardableResult private func apply(_ next: [String]) -> Bool {
    do {
      try change(next)
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
}
struct CourseOccurrence: Identifiable {
  let course: WorkspaceItem
  let meeting: WorkspaceItem
  let day: Date
  let start: String
  let end: String
  let inactiveLabel: String?
  var id: String { meeting.id + Clock.day(day) }
}
func courseOccurrences(
  snapshot: WorkspaceSnapshot, day: Date, allWeek: Bool = false, includeInactive: Bool = false
)
  -> [CourseOccurrence]
{
  let calendar = Clock.calendar
  let days =
    allWeek
    ? (0..<7).compactMap {
      calendar.date(
        byAdding: .day, value: $0, to: calendar.dateInterval(of: .weekOfYear, for: day)!.start)
    } : [day]
  return days.flatMap { date in
    snapshot[.courseMeetings].compactMap { meeting -> CourseOccurrence? in
      guard let course = snapshot.item(.courses, meeting[.courseID].string),
        let term = snapshot.item(.semesters, course[.semesterID].string),
        let first = try? Clock.parse(term[.firstMonday].string + "T00:00:00+08:00"),
        date >= first
      else { return nil }
      let week =
        (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? -7)
        / 7 + 1
      let weekday = (calendar.component(.weekday, from: date) + 5) % 7 + 1
      let weeks = (try? JSONValue(json: meeting[.weeks].string).array.map(\.int)) ?? []
      guard
        week > 0 && week <= term[.weeks].int && weeks.contains(Int64(week))
          && meeting[.weekday].int == weekday
      else { return nil }
      let periods = (try? JSONValue(json: term[.periods].string).array) ?? []
      let start = periods.first { $0["number"] == meeting[.periodStart] }?["start"].string ?? ""
      let end = periods.first { $0["number"] == meeting[.periodEnd] }?["end"].string ?? ""
      var inactiveLabel: String?
      if course.status == "paused" { inactiveLabel = "已暂停" }
      if course.status == "done" {
        let completed = try? Clock.parse(course.fields.text("completed_at"))
        let begins = try? Clock.parse(Clock.day(date) + "T" + start + ":00+08:00")
        if let completed, let begins {
          if begins >= completed { inactiveLabel = "已完结" }
        } else {
          inactiveLabel = "已完结"
        }
      }
      guard includeInactive || inactiveLabel == nil else { return nil }
      return CourseOccurrence(
        course: course, meeting: meeting, day: date, start: start, end: end, inactiveLabel: inactiveLabel)
    }
  }.sorted { (Clock.day($0.day), $0.start) < (Clock.day($1.day), $1.start) }
}
struct CoursesView: View {
  @Environment(AppSession.self) private var session
  @State private var reminders = false
  @State private var addCourse = false
  @State private var editSemester = false
  @State private var addSemester = false
  @State private var week = Date()
  @State private var semesterID = ""
  @State private var showTable = true
  @State private var courseSearch = ""
  @State private var selectedCourse: WorkspaceItem?
  @State private var addedCourseID: String?

  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var semesters: [WorkspaceItem] {
    snapshot[.semesters].sorted { $0[.firstMonday].string > $1[.firstMonday].string }
  }
  private var selectedSemester: WorkspaceItem? { semesters.first { $0.id == semesterID } }
  private var semesterCourses: [WorkspaceItem] {
    let rows = snapshot[.courses].filter { $0[.semesterID].string == semesterID }
    guard let addedCourseID, let row = rows.first(where: { $0.id == addedCourseID }) else { return rows }
    return [row] + rows.filter { $0.id != addedCourseID }
  }
  private var filteredCourses: [WorkspaceItem] {
    let q = courseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return semesterCourses }
    return semesterCourses.filter {
      $0.title.localizedCaseInsensitiveContains(q)
        || $0[.teacher].string.localizedCaseInsensitiveContains(q)
        || $0[.code].string.localizedCaseInsensitiveContains(q)
    }
  }
  private var isViewingCurrentWeek: Bool {
    Clock.calendar.isDate(week, equalTo: .now, toGranularity: .weekOfYear)
  }
  private var hasAnyMeetingsInSemester: Bool {
    let courseIDs = Set(semesterCourses.map(\.id))
    return snapshot[.courseMeetings].contains { courseIDs.contains($0[.courseID].string) }
  }

  var body: some View {
    VStack(spacing: WorkbenchDesign.Space.medium) {
      if semesters.isEmpty {
        ContentUnavailableView {
          Label("创建第一个学期", systemImage: "graduationcap")
        } description: {
          Text("新建学期会自动生成标准作息节次；你也可以将课表截图或 Excel 发给微信助手一键导入。")
        } actions: {
          Button("新建学期") { addSemester = true }
            .buttonStyle(.borderedProminent)
        }
      } else if semesterCourses.isEmpty {
        ContentUnavailableView {
          Label("「\(selectedSemester?.title ?? "本学期")」暂无课程", systemImage: "graduationcap")
        } description: {
          Text("添加课程时可一并勾选上课星期、节次与教学周。")
        } actions: {
          Button("添加课程") { addCourse = true }
            .buttonStyle(.borderedProminent)
        }
      } else if showTable {
        courseHeader
        CourseSchedule(
          week: week,
          semesterID: semesterID,
          hasUnscheduledCourses: !hasAnyMeetingsInSemester,
          isCurrentWeek: isViewingCurrentWeek,
          onBackToCurrentWeek: { week = .now },
          onShowCourseCards: { showTable = false },
          onAddCourse: { addCourse = true }
        ) { selectedCourse = $0 }
      } else {
        courseHeader
        if filteredCourses.isEmpty {
          EmptyState(title: "未找到匹配课程", symbol: "magnifyingglass", detail: "试试其他课程名或教师姓名。")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            CollectionBoardLayout {
              ForEach(filteredCourses) { item in
                CourseCard(item: item) { selectedCourse = item }
              }
            }
            .padding(.bottom, WorkbenchDesign.Space.group)
          }
          .scrollDismissesKeyboard(.interactively)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .workspacePage()
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button(semesters.isEmpty ? "新建学期" : "添加课程", systemImage: "plus") {
            if semesters.isEmpty {
              addSemester = true
            } else {
              addCourse = true
            }
          }
          .accessibilityIdentifier("course.new")
        }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            if !semesters.isEmpty {
              Picker("学期", selection: $semesterID) {
                ForEach(semesters) { Text($0.title).tag($0.id) }
              }
              Divider()
              Button("添加课程", systemImage: "plus") { addCourse = true }
            }
            Button("学期管理", systemImage: "calendar.badge.clock") { editSemester = true }
            Button("课程提醒", systemImage: "bell") { reminders = true }
          } label: {
            Label("课程管理", systemImage: "ellipsis").labelStyle(.iconOnly)
          }
          .menuIndicator(.hidden)
        }
      }
      .sheet(isPresented: $addSemester) { SemesterEditor() }
      .sheet(isPresented: $reminders) { CourseRemindersView() }
      .sheet(isPresented: $addCourse) {
        CourseEditor(defaultSemesterID: semesterID) { item, scheduled in
          semesterID = item[.semesterID].string
          addedCourseID = item.id
          if !scheduled {
            showTable = false
          }
        }
      }
      .sheet(isPresented: $editSemester) {
        SemesterManagementView()
      }
      .onChange(of: semesters.map(\.id), initial: true) { old, ids in
        if let added = ids.first(where: { !old.contains($0) }), !old.isEmpty { semesterID = added }
        else if !ids.contains(semesterID) {
          semesterID = semesters.first(where: { $0[.firstMonday].string <= Clock.day() })?.id ?? ids.first ?? ""
        }
      }
      .onChange(of: semesterID) { _, id in
        if let term = semesters.first(where: { $0.id == id }),
          let date = try? Clock.parse(term[.firstMonday].string + "T00:00:00+08:00") {
          let end = date.addingTimeInterval(Double(term[.weeks].int) * 7 * 86400)
          week = Date.now >= date && Date.now < end ? .now : date
        }
      }
      #if os(macOS)
        .sheet(item: $selectedCourse) { item in
          NavigationStack {
            CollectionDetail(route: .init(entity: .courses, id: item.id)).toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("关闭") { selectedCourse = nil } }
            }
          }.frame(minWidth: 520, idealWidth: 680, minHeight: 460, idealHeight: 680)
        }
      #else
        .navigationDestination(
          isPresented: Binding(
            get: { selectedCourse != nil }, set: { if !$0 { selectedCourse = nil } })
        ) {
          if let selectedCourse {
            CollectionDetail(route: .init(entity: .courses, id: selectedCourse.id))
          }
        }
      #endif

  }
  private func shiftWeek(_ offset: Int) {
    week = Clock.calendar.date(byAdding: .day, value: offset * 7, to: week)!
  }
  private var courseHeader: some View {
    HStack(spacing: WorkbenchDesign.Space.small) {
      WorkspaceFilters(
        values: [true, false],
        selection: $showTable,
        title: { $0 ? "课表" : "课程" },
        count: { $0 ? 0 : semesterCourses.count }
      )
      if let selectedSemester, semesters.count > 1 {
        Text(selectedSemester.title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(WorkbenchDesign.fieldBackground, in: .capsule)
      }
      Spacer(minLength: 0)
      if showTable {
        if !isViewingCurrentWeek {
          Button("本周") { week = .now }
            .font(.subheadline)
        }
        Button("上一周", systemImage: "chevron.left") { shiftWeek(-1) }.labelStyle(.iconOnly)
        Text(weekLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        Button("下一周", systemImage: "chevron.right") { shiftWeek(1) }.labelStyle(.iconOnly)
      } else {
        WorkspaceSearch(prompt: "搜索课程", text: $courseSearch)
          .frame(maxWidth: 220)
      }
    }
  }

  private var weekLabel: String {
    let monday = Clock.calendar.dateInterval(of: .weekOfYear, for: week)!.start
    let sunday = Clock.calendar.date(byAdding: .day, value: 6, to: monday)!
    var format = Date.FormatStyle().month(.twoDigits).day(.twoDigits)
    format.timeZone = Clock.calendar.timeZone
    let range = monday.formatted(format) + "–" + sunday.formatted(format)
    guard let term = selectedSemester,
      let first = try? Clock.parse(term[.firstMonday].string + "T00:00:00+08:00"),
      let days = Clock.calendar.dateComponents([.day], from: first, to: monday).day,
      days >= 0, days / 7 < term[.weeks].int
    else { return range }
    return "第\(days / 7 + 1)周 · " + range
  }

}
