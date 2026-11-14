import SwiftUI

struct PhotoRoute: Hashable { let id: String }
struct PhotoList: View {
  var initialStage: PhotoStage?
  @Environment(AppSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var stage: PhotoStage?
  @State private var search = ""
  @State private var newOrder = false
  @State private var savedOrder: String?
  @State private var createdOrder: String?
  @State private var sharing = false
  @State private var selectedOrder: String?
  @State private var showingColumns = false
  @Namespace private var transition
  private var orders: [PhotoOrder] {
    (session.photos?.snapshot.orders ?? []).filter {
      (stage == nil || $0.stage == stage)
        && (search.isEmpty || $0.brand.localizedCaseInsensitiveContains(search)
          || $0[.requirements].string.localizedCaseInsensitiveContains(search))
    }
    .sorted { lhs, rhs in
      if (lhs.stage == .completed) != (rhs.stage == .completed) { return lhs.stage != .completed }
      let a = lhs[.deadline].string
      let b = rhs[.deadline].string
      return (a.isEmpty ? "9999" : a, lhs.id) < (b.isEmpty ? "9999" : b, rhs.id)
    }
  }
  var body: some View {
    Group {
      if let store = session.photos, store.snapshot.workspace.isNull || store.snapshot.locked {
        PhotoConnectionView()
      } else {
        #if os(macOS)
          GeometryReader { geometry in
            if geometry.size.width >= 780 {
              HSplitView {
                browser(selection: true).frame(minWidth: 320, idealWidth: 340, maxWidth: 360)
                Group {
                  if let selectedOrder, session.photos?.snapshot.order(selectedOrder) != nil {
                    PhotoDetail(id: selectedOrder).id(selectedOrder)
                  } else {
                    ContentUnavailableView("选择一张订单", systemImage: "camera")
                  }
                }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
              }
            } else {
              browser(selection: false)
            }
          }.onGeometryChange(for: Bool.self) {
            $0.size.width >= 780
          } action: {
            showingColumns = $0
          }
        #else
          browser(selection: false)
        #endif
      }
    }
    .toolbar {
      #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
          Button("添加订单", systemImage: "plus") { newOrder = true }.disabled(
            session.photos?.snapshot.workspace.isNull != false
              || session.photos?.snapshot.locked == true)
        }
        ToolbarItem(placement: .primaryAction) {
          Button("共享空间", systemImage: "person.2") { sharing = true }
        }
      #endif
    }
    .phoneCreateAction(
      "添加订单",
      enabled: session.photos?.snapshot.workspace.isNull == false
        && session.photos?.snapshot.locked == false
    ) { newOrder = true }
    .navigationDestination(for: PhotoRoute.self) { route in
      #if os(iOS)
        PhotoDetail(id: route.id).navigationTransition(.zoom(sourceID: route.id, in: transition))
      #else
        PhotoDetail(id: route.id)
      #endif
    }
    .sheet(
      isPresented: $newOrder,
      onDismiss: {
        if let id = savedOrder {
          if showingColumns { selectedOrder = id } else { createdOrder = id }
          savedOrder = nil
        }
      }
    ) { NavigationStack { NewPhotoOrderView(onSaved: { savedOrder = $0 }) } }
    .navigationDestination(item: $createdOrder) { PhotoDetail(id: $0) }
    .sheet(isPresented: $sharing) {
      NavigationStack {
        PhotoConnectionView().navigationTitle("拍照共享").toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("关闭") { sharing = false } }
        }
      }
    }
    .onAppear { if let initialStage { stage = initialStage } }
    #if os(macOS)
      .onChange(of: orders.map(\.id), initial: true) { _, ids in
        if selectedOrder == nil || !ids.contains(selectedOrder!) { selectedOrder = ids.first }
      }
    #endif
  }
  private func browser(selection: Bool) -> some View {
    VStack(spacing: 0) {
      WorkspaceSearch(prompt: "搜索品牌或拍摄要求", text: $search).padding(
        .horizontal, WorkbenchDesign.masterInset
      ).padding(.top, WorkbenchDesign.Space.medium)
      statusTabs
      WorkspaceList(selection: selection ? $selectedOrder : nil, inset: WorkbenchDesign.masterInset) {
        ForEach(orders) { order in
          if selection {
            PhotoOrderRow(order: order).tag(order.id)
          } else {
            NavigationLink(value: PhotoRoute(id: order.id)) {
              PhotoOrderRow(order: order).matchedTransitionSource(id: order.id, in: transition)
            }
          }
        }
      }
      .overlay {
        if orders.isEmpty {
          ContentUnavailableView(search.isEmpty ? "暂无订单" : "没有找到订单", systemImage: "camera")
        }
      }
      .refreshable { await session.sync() }
    }.background(WorkbenchDesign.canvas)
  }
  private var statusTabs: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        filterButton(nil)
        ForEach(PhotoStage.allCases) { filterButton($0) }
      }.padding(.horizontal, WorkbenchDesign.masterInset).padding(.vertical, 8)
    }.scrollIndicators(.hidden)
  }
  private func filterButton(_ value: PhotoStage?) -> some View {
    let count =
      session.photos?.snapshot.orders.filter { value == nil || $0.stage == value }.count ?? 0
    return Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { stage = value }
    } label: {
      HStack(spacing: 5) {
        Text(value?.title ?? "汇总")
        if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
      }
      .font(.subheadline.weight(stage == value ? .semibold : .regular)).padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(stage == value ? Color.accentColor.opacity(0.1) : .clear, in: Capsule())
      .foregroundStyle(stage == value ? Color.accentColor : .secondary)
    }.buttonStyle(.plain).accessibilityAddTraits(stage == value ? .isSelected : [])
  }
}
struct PhotoOrderRow: View {
  let order: PhotoOrder
  @Environment(AppSession.self) private var session
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      if let attachment = session.photos?.snapshot.attachments.first(where: {
        $0.id == order.images.first
      }), let directory = session.location?.directory {
        AttachmentThumbnail(
          attachment: attachment, directory: directory.appendingPathComponent("photo-attachments")
        ).frame(width: 64, height: 76).clipped().clipShape(.rect(cornerRadius: 9))
      } else {
        Image(systemName: "photo").foregroundStyle(.tertiary).frame(width: 64, height: 76)
          .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 9))
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(order.brand).font(.headline).lineLimit(2)
        HStack(spacing: 8) {
          Label(order.stage.title, systemImage: order.stage.symbol).font(.caption.weight(.medium))
            .foregroundStyle(stageColor(order.stage))
          if !order[.deadline].string.isEmpty {
            Text(deadlineLabel(order)).font(.caption).foregroundStyle(
              order[.deadline].string < Clock.day() && order.stage != .completed ? .red : .secondary
            )
          }
        }
        if !order[.requirements].string.isEmpty {
          Text(order[.requirements].string).font(.subheadline).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(.vertical, 6).accessibilityElement(children: .combine)
  }
}
func stageColor(_ stage: PhotoStage) -> Color {
  switch stage {
  case .output: .blue
  case .review: .purple
  case .return: .orange
  case .submit: .teal
  case .refund: .indigo
  case .completed: .secondary
  }
}
func deadlineLabel(_ order: PhotoOrder) -> String {
  let day = order[.deadline].string
  return day == Clock.day()
    ? "今天截止"
    : day < Clock.day() && order.stage != .completed
      ? "逾期 · " + day.suffix(5)
      : String(day.suffix(5)).replacingOccurrences(of: "-", with: "/") + " 截止"
}
struct PhotoFieldEdit: Identifiable {
  let field: PhotoField
  let before: JSONValue
  var text: String
  var id: String { field.rawValue }
  init(_ field: PhotoField, order: PhotoOrder) {
    self.field = field
    before = order[field]
    text =
      [.postage, .commission].contains(field)
      ? (before.isNull ? "" : String(format: "%.2f", Double(before.int) / 100))
      : field == .notes ? visiblePhotoNotes(order) : before.string
  }
  func value(order: PhotoOrder) throws -> JSONValue {
    if [.postage, .commission].contains(field) {
      return try Money.parse(text).map(JSONValue.integer) ?? .null
    }
    if field == .notes {
      let original = order[.notes].string.components(separatedBy: "\n").filter {
        isPhotoProvenance($0, order: order)
      }
      return .string(
        ([text.trimmingCharacters(in: .whitespacesAndNewlines)] + original).filter { !$0.isEmpty }
          .joined(separator: "\n"))
    }
    return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
enum Money {
  static func parse(_ text: String) throws -> Int64? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    try require(
      text.range(of: "^\\d+(?:\\.\\d{0,2})?$", options: .regularExpression) != nil, "金额最多保留两位小数")
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard let whole = Int64(parts[0]), whole <= 10_000_000 else { throw WorkBenchError("金额超出范围") }
    let fraction =
      parts.count > 1 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
    let cents = whole * 100 + (Int64(fraction) ?? 0)
    try require(cents <= 1_000_000_000, "金额超出范围")
    return cents
  }
}
func isPhotoProvenance(_ line: String, order: PhotoOrder) -> Bool {
  guard !order.fields[value: "import_source"].isNull else { return false }
  return line.range(
    of: "^同品牌分件记录：第 \\d+/\\d+ 件，原品牌填写为「.*」。$|^出图要求沿用原表合并单元格 [A-Z]+\\d+。$",
    options: .regularExpression) != nil || line == "原表进度未填写，导入时暂列待出图。"
    || (line.hasPrefix("来源：") && line.hasSuffix("历史操作时间未提供。"))
}
func visiblePhotoNotes(_ order: PhotoOrder) -> String {
  order[.notes].string.components(separatedBy: "\n").filter { !isPhotoProvenance($0, order: order) }
    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
struct PhotoDetail: View {
  let id: String
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var editing: PhotoFieldEdit?
  @State private var saving = false
  @State private var advancing = false
  @State private var saveError: String?
  @State private var deleteConfirmation = false
  @State private var manageImages = false
  @State private var reviewingChanges = false
  @State private var galleryHeight = WorkbenchDesign.PhotoLayout.imageHeight
  @FocusState private var fieldFocused: Bool
  private var order: PhotoOrder? { session.photos?.snapshot.order(id) }
  var body: some View {
    Group {
      if let order {
        WorkspaceDetailPage {
          if !orderConflicts.isEmpty {
            HStack(spacing: WorkbenchDesign.Space.small) {
              Label("有共享修改待核对", systemImage: "arrow.triangle.branch")
                .font(.subheadline).foregroundStyle(.secondary)
              Spacer(minLength: 0)
              Button("核对修改") { reviewingChanges = true }
                .accessibilityIdentifier("photo.reviewChanges")
            }
          }
          #if os(macOS)
            orderSummary(order)
          #endif
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: WorkbenchDesign.Space.group) {
              screenshotSection(order).frame(width: WorkbenchDesign.PhotoLayout.imageWidth)
              requirementsSection(order).frame(minWidth: WorkbenchDesign.PhotoLayout.summaryMinimum)
            }
            VStack(alignment: .leading, spacing: WorkbenchDesign.Space.section) {
              screenshotSection(order)
              requirementsSection(order)
            }
          }
          Divider()
          HStack(alignment: .top, spacing: WorkbenchDesign.Space.section) {
            fieldRow(.postage, order: order).frame(maxWidth: .infinity, alignment: .leading)
            fieldRow(.commission, order: order).frame(maxWidth: .infinity, alignment: .leading)
          }
          fieldRow(.notes, order: order, labeled: !visiblePhotoNotes(order).isEmpty)
        }
        .accessibilityIdentifier("photo.detail.content")
        #if os(iOS)
          .safeAreaInset(edge: .top, spacing: 0) {
            orderSummary(order)
            .padding(.horizontal, WorkbenchDesign.pageInset)
            .padding(.vertical, WorkbenchDesign.Space.small)
            .background(WorkbenchDesign.canvas)
          }
        #endif
        .onGeometryChange(for: CGFloat.self) { geometry in
          min(560, max(300, finiteLayoutHeight(geometry.size.height, fallback: 640) * 0.65))
        } action: { value in
          #if os(iOS)
            if abs(galleryHeight - value) > 1 { galleryHeight = value }
          #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(order) }
        .navigationTitle("").phoneDetailNavigation()
        #if os(iOS)
        .toolbar {
          if editing != nil && editing?.field != .deadline {
            ToolbarItem(placement: .cancellationAction) {
              Button("取消") {
                editing = nil
                saveError = nil
                fieldFocused = false
              }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
              Button {
                save(order)
              } label: {
                if saving { ProgressView() } else { Image(systemName: "checkmark") }
              }.accessibilityLabel("完成修改").disabled(saving)
            }
          } else {
            ToolbarItem(placement: .primaryAction) {
              Menu("订单操作", systemImage: "ellipsis") {
                Button("删除订单", systemImage: "trash", role: .destructive) {
                  deleteConfirmation = true
                }
              }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityIdentifier("photo.actions")
            }
          }
        }
        #endif
        .confirmationDialog(
          "永久删除这张订单？", isPresented: $deleteConfirmation, titleVisibility: .visible
        ) {
          Button("永久删除", role: .destructive) {
            session.run {
              _ = try await session.photos?.perform(
                .delete(id: id, expectedRevision: order.revision))
              dismiss()
            }
          }
        }
        .sheet(isPresented: $reviewingChanges, onDismiss: {
          if orderConflicts.isEmpty, let edit = editing, let current = self.order {
            var rebased = PhotoFieldEdit(edit.field, order: current)
            rebased.text = edit.text
            editing = rebased
            saveError = nil
          }
        }) {
          NavigationStack {
            Form {
              if editing != nil {
                Section { Text("当前输入会保留，核对后请再次点完成。").foregroundStyle(.secondary) }
              }
              if orderConflicts.isEmpty {
                Section { Label("已核对完成", systemImage: "checkmark.circle") }
              }
              ForEach(orderConflicts) { conflict in
                Section { PhotoConflictReview(conflict: conflict, initiallyExpanded: true) }
              }
            }.workspaceSettingsForm().navigationTitle("核对修改").phoneDetailNavigation()
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("完成") { reviewingChanges = false }
                }
              }
          }
        }
        .sheet(isPresented: $manageImages) {
          NavigationStack {
            WorkspaceList {
              ForEach(order.images, id: \.self) { imageID in
                if let attachment = session.photos?.snapshot.attachments.first(where: {
                  $0.id == imageID
                }) {
                  HStack {
                    Text(attachment.name)
                    Spacer()
                    Button("移除", systemImage: "trash", role: .destructive) {
                      session.run {
                        _ = try await session.photos?.perform(
                          .patch(
                            id: id, field: .images, before: order[.images],
                            value: .array(
                              order.images.filter { $0 != imageID }.map(JSONValue.string))))
                      }
                    }
                  }
                }
              }
            }.navigationTitle("订单截图").toolbar {
              ToolbarItem(placement: .confirmationAction) { Button("完成") { manageImages = false } }
            }
          }
        }
      } else {
        EmptyState(title: "订单已不存在", symbol: "camera", detail: "返回列表查看其他订单。")
      }
    }
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
  private func requirementsSection(_ order: PhotoOrder) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      Text("拍摄要求").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
      fieldRow(.requirements, order: order, labeled: false)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func actionBar(_ order: PhotoOrder) -> some View {
    if saveError != nil || (editing == nil && order.stage.next != nil) {
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
        if let saveError {
          Label(saveError, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.red)
        }
        if editing == nil, let next = order.stage.next {
          Button {
            guard !advancing, let store = session.photos else { return }
            advancing = true
            saveError = nil
            Task {
              defer { advancing = false }
              do {
                _ = try await store.perform(
                  .transition(
                    id: id, stage: next,
                    expectedRevision: order.workflowRevision))
                session.scheduleSync()
              } catch { self.saveError = error.localizedDescription }
            }
          } label: {
            HStack {
              if advancing { ProgressView() } else { Image(systemName: "checkmark") }
              Text(advanceLabel(order.stage))
            }.frame(maxWidth: .infinity)
          }.buttonStyle(.borderedProminent).controlSize(.large).disabled(advancing)
            .accessibilityIdentifier("photo.advance")
        }
      }.padding(.horizontal, WorkbenchDesign.pageInset).padding(
        .vertical, WorkbenchDesign.Space.small
      )
      .frame(maxWidth: WorkbenchDesign.readingWidth).frame(maxWidth: .infinity).background(.bar)
    }
  }
  private func screenshotSection(_ order: PhotoOrder) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      HStack(spacing: WorkbenchDesign.Space.section) {
        Text("订单截图").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        Spacer()
        if !order.images.isEmpty {
          addScreenshot.labelStyle(.iconOnly).accessibilityLabel("添加截图")
          Button("管理截图", systemImage: "square.grid.2x2") { manageImages = true }
            .labelStyle(.iconOnly).accessibilityIdentifier("photo.images.manage")
        }
      }.buttonStyle(.borderless).foregroundStyle(.secondary)
      if let location = session.location {
        let attachments = order.images.compactMap { imageID in
          session.photos?.snapshot.attachments.first { $0.id == imageID }
        }
        if !attachments.isEmpty {
          PhotoGallery(
            attachments: attachments,
            directory: location.directory.appendingPathComponent("photo-attachments"),
            height: galleryHeight
          )
          .frame(height: galleryHeight)
        } else {
          addScreenshot.frame(
            maxWidth: .infinity, minHeight: WorkbenchDesign.controlHeight,
            alignment: .leading
          ).buttonStyle(.borderless)
        }
      }
    }
  }
  private var addScreenshot: some View {
    MediaPicker(title: "添加截图", imagesOnly: true) { data, name in
      guard let store = session.photos else { return }
      let attachment = try await store.database.importImage(data: data, name: name, orderID: id)
      let images = store.snapshot.order(id)?[.images] ?? .array([])
      _ = try await store.perform(
        .patch(
          id: id, field: .images, before: images,
          value: .array(images.array + [.string(attachment.id)])))
    }.menuStyle(.borderlessButton)
  }
  private func orderSummary(_ order: PhotoOrder) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      HStack(alignment: .top, spacing: WorkbenchDesign.Space.medium) {
      fieldRow(.brand, order: order, labeled: false, emphasized: true)
        #if os(macOS)
          Spacer(minLength: 0)
          orderActions(order)
        #endif
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchDesign.Space.section) {
          stagePicker(order)
          deadlineField(order)
        }
        VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
          stagePicker(order)
          deadlineField(order)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func stagePicker(_ order: PhotoOrder) -> some View {
    Menu {
      ForEach(PhotoStage.allCases) { stage in
        Button(stage.title, systemImage: stage.symbol) {
          guard !advancing else { return }
          session.run {
            _ = try await session.photos?.perform(
              .transition(id: id, stage: stage, expectedRevision: order.workflowRevision))
          }
        }
      }
    } label: {
      Label(order.stage.title, systemImage: order.stage.symbol)
        .font(.subheadline.weight(.medium)).foregroundStyle(stageColor(order.stage))
        .padding(.horizontal, WorkbenchDesign.Space.small).padding(.vertical, 5)
        .background(stageColor(order.stage).opacity(0.08), in: .capsule)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(advancing)
      .accessibilityIdentifier("photo.stage")
  }
  private func deadlineField(_ order: PhotoOrder) -> some View {
    Button {
      editing = PhotoFieldEdit(.deadline, order: order)
      saveError = nil
      fieldFocused = false
    } label: {
      let day = order[.deadline].string
      Label(day.isEmpty ? "添加截止日" : String(day.suffix(5)).replacingOccurrences(of: "-", with: "/") + " 截止",
        systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
    }.buttonStyle(.plain).accessibilityIdentifier("photo.field.deadline")
      .popover(isPresented: Binding(get: { editing?.field == .deadline },
        set: { if !$0 && !saving { editing = nil } })) {
          VStack(spacing: WorkbenchDesign.Space.section) {
            OptionalDateField(value: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }), expanded: true)
            orderEditActions(order)
            if let saveError { Text(saveError).font(.footnote).foregroundStyle(.red) }
          }.padding(WorkbenchDesign.Space.section).frame(width: 340)
            .presentationCompactAdaptation(.popover).interactiveDismissDisabled(saving)
      }
  }
  @ViewBuilder private func orderActions(_ order: PhotoOrder) -> some View {
    if editing != nil && editing?.field != .deadline {
      orderEditActions(order)
    } else {
      Menu("订单操作", systemImage: "ellipsis") {
        Button("删除订单", systemImage: "trash", role: .destructive) { deleteConfirmation = true }
      }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityIdentifier("photo.actions")
    }
  }
  private func orderEditActions(_ order: PhotoOrder) -> some View {
    HStack(spacing: WorkbenchDesign.Space.small) {
      Button("取消") { editing = nil; saveError = nil; fieldFocused = false }.disabled(saving)
      Button { save(order) } label: {
        if saving { ProgressView() } else { Text("完成") }
      }.buttonStyle(.borderedProminent).disabled(saving).accessibilityLabel("完成修改")
    }.fixedSize()
  }
  private func fieldRow(
    _ field: PhotoField, order: PhotoOrder, labeled: Bool = true, emphasized: Bool = false
  ) -> some View {
    Group {
      if editing?.field == field {
        VStack(alignment: .leading, spacing: 8) {
          if labeled { Text(field.title).font(.caption).foregroundStyle(.secondary) }
          TextField(
            field.title, text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }),
            axis: .vertical
          ).lineLimit(1...14).focused($fieldFocused).workspaceInput(focused: true)
            .accessibilityIdentifier("photo.edit." + field.rawValue)
        }.padding(.vertical, 4)
      } else {
        Button {
          editing = PhotoFieldEdit(field, order: order)
          saveError = nil
          fieldFocused = true
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            if labeled { Text(field.title).font(.caption).foregroundStyle(.secondary) }
            let text =
              field == .notes
              ? visiblePhotoNotes(order)
              : [.postage, .commission].contains(field)
                ? (order[field].isNull
                  ? "" : "¥" + String(format: "%.2f", Double(order[field].int) / 100))
                : order[field].string
            let placeholder = [.postage, .commission].contains(field) ? "添加" : "添加" + field.title
            Text(text.isEmpty ? placeholder : text).foregroundStyle(
              text.isEmpty ? .secondary : .primary
            ).frame(maxWidth: .infinity, alignment: .leading).fixedSize(
              horizontal: false, vertical: true)
          }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("轻点原地修改").accessibilityIdentifier(
          "photo.field." + field.rawValue)
      }
    }.font(
      emphasized
        ? WorkbenchDesign.Typography.detailTitle
        : [.postage, .commission].contains(field) ? .subheadline : .body)
  }
  private var orderConflicts: [SyncConflict] {
    session.photos?.snapshot.conflicts.filter { $0.recordID == id } ?? []
  }
  private func save(_ order: PhotoOrder) {
    guard let edit = editing, let store = session.photos else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        _ = try await store.perform(
          .patch(id: id, field: edit.field, before: edit.before, value: edit.value(order: order)))
        editing = nil
        saveError = nil
        fieldFocused = false
        session.scheduleSync()
      } catch { saveError = error.localizedDescription }
    }
  }
}
func advanceLabel(_ stage: PhotoStage) -> String {
  switch stage {
  case .output: "标记已出图"
  case .review: "审图通过"
  case .return: "标记已寄回"
  case .submit: "标记已提交"
  case .refund: "标记已返款"
  case .completed: "已完成"
  }
}
struct NewPhotoOrderView: View {
  var onSaved: (String) -> Void = { _ in }
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var input = PhotoOrderInput()
  @State private var postage = ""
  @State private var commission = ""
  @State private var saving = false
  @State private var error: String?
  @State private var saved = false
  var body: some View {
    Form {
      Section {
        TextField("品牌（必填）", text: $input.brand, axis: .vertical).lineLimit(1...4)
          .accessibilityIdentifier("order.brand.input")
        Picker("进度", selection: $input.stage) {
          ForEach(PhotoStage.allCases.filter { $0 != .completed }) { Text($0.title).tag($0) }
        }
      }
      Section("订单截图") {
        if !input.images.isEmpty { Text("已添加 \(input.images.count) 张").foregroundStyle(.secondary) }
        MediaPicker(title: "添加截图", imagesOnly: true) { data, name in
          guard let store = session.photos else { return }
          try require(input.images.count < 10, "每单最多 10 张截图")
          let attachment = try await store.database.importImage(
            data: data, name: name, orderID: input.id)
          input.images.append(attachment.id)
        }
      }
      Section("拍摄要求") {
        TextField("稍后也可以补充", text: $input.requirements, axis: .vertical).lineLimit(2...12)
      }
      Section("更多信息（选填）") {
        OptionalDateField(value: $input.deadline)
        TextField("邮费", text: $postage)
        TextField("佣金", text: $commission)
        TextField("备注", text: $input.notes, axis: .vertical).lineLimit(1...10)
      }
      if let error { Text(error).foregroundStyle(.red) }
    }
    .workspaceSheetForm(height: 580)
    .navigationTitle("新建订单")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          guard !saving, let store = session.photos else { return }
          saving = true
          Task {
            defer { saving = false }
            do {
              input.postage = try Money.parse(postage)
              input.commission = try Money.parse(commission)
              _ = try await store.perform(.create(input))
              saved = true
              session.scheduleSync()
              onSaved(input.id)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }.disabled(saving || input.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .interactiveDismissDisabled(saving)
    .onDisappear {
      if !saved {
        let id = input.id
        Task { try? await session.photos?.database.discardUnpublishedImages(orderID: id) }
      }
    }
  }
}
struct PhotoConnectionView: View {
  @Environment(AppSession.self) private var session
  @State private var link = ""
  @State private var email = ""
  @State private var invitation: String?
  var body: some View {
    Form {
      if session.photos?.snapshot.workspace.isNull != false {
        Section {
          Label("我们的拍照空间", systemImage: "person.2").font(.headline)
          Text("两个人使用各自的 iCloud 账号，共同查看和更新订单。").foregroundStyle(.secondary)
          Button("查找已有空间", systemImage: "arrow.clockwise") {
            session.run { try await session.connectPhotos() }
          }
          ForEach(session.foundSpaces, id: \.self) { space in
            Button("连接 " + space["zone"].string) {
              session.run { try await session.connectPhotos(selected: space) }
            }
          }
          Button("创建空间", systemImage: "plus") {
            session.run { try await session.connectPhotos(create: true) }
          }
        }
        Section("加入邀请") {
          TextField("iCloud 邀请链接", text: $link)
          Button("加入") { session.run { try await session.connectPhotos(invitation: link) } }
            .disabled(link.isEmpty)
        }
      } else {
        Section {
          Label("已连接拍照空间", systemImage: "checkmark.icloud")
          Button("立即同步", systemImage: "arrow.triangle.2.circlepath") {
            Task { await session.sync() }
          }
        }
        if session.photos?.snapshot.workspace["scope"] == .string("private") {
          Section("邀请她加入") {
            TextField("她的 iCloud 邮箱", text: $email)
            Button("生成邀请链接") {
              session.run { invitation = try await session.invitation(email: email) }
            }.disabled(email.isEmpty)
            if let invitation, let url = URL(string: invitation) { ShareLink("分享邀请", item: url) }
          }
        }
      }
      if let store = session.photos, !store.snapshot.conflicts.isEmpty {
        Section("核对共享修改") {
          ForEach(store.snapshot.conflicts) { PhotoConflictReview(conflict: $0) }
        }
      }
      if !session.syncMessage.isEmpty {
        Section { Text(session.syncMessage).font(.footnote).foregroundStyle(.secondary) }
      }
    }.workspaceSettingsForm()
  }
}
