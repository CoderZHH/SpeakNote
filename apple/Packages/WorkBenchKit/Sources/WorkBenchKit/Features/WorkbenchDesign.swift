import SwiftUI

/// Shared layout rules. Feature pages adapt composition without duplicating business logic.
enum WorkbenchDesign {
  #if os(macOS)
    static let pageInset: CGFloat = 24
  #else
    static let pageInset: CGFloat = 16
  #endif
  enum Space {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let section: CGFloat = 16
    static let group: CGFloat = 20
  }
  enum ItemActions {
    static let width: CGFloat = 280
    static let swatchDiameter: CGFloat = 20
    #if os(macOS)
      static let actionHeight: CGFloat = 32
      static let swatchTarget: CGFloat = 36
    #else
      static let actionHeight: CGFloat = 44
      static let swatchTarget: CGFloat = 44
    #endif
  }
  enum SelectionLayout {
    static let height: CGFloat = 420
  }
  enum ThoughtLayout {
    static let editorWidth: CGFloat = 520
    static let editorHeight: CGFloat = 480
    static let tagPickerWidth: CGFloat = 300
    static let tagListHeight: CGFloat = 220
  }
  enum FocusLayout {
    static let menuTimerWidth: CGFloat = 70
    static let menuPanelWidth: CGFloat = 300
  }
  enum PhotoLayout {
    static let imageWidth: CGFloat = 380
    static let imageHeight: CGFloat = 400
    static let summaryMinimum: CGFloat = 280
  }
  enum CalendarLayout {
    static let splitWidth: CGFloat = 820
    static let agendaWidth: CGFloat = 300
    static let dayHeight: CGFloat = 44
    static let previewHeight: CGFloat = 18
    static let weekdayHeight: CGFloat = 28
    static let dateDiameter: CGFloat = 28
    static let timelineAxisWidth: CGFloat = 48
    static let timelineColumnMinimum: CGFloat = 100
    static let timelineHeaderHeight: CGFloat = 46
    static let timelineHourHeight: CGFloat = 56
  }
  static let rowInset: CGFloat = Space.small
  static let masterInset: CGFloat = Space.section
  static let sheetInset: CGFloat = 24
  static let sheetWidth: CGFloat = 500
  static let formWidth: CGFloat = 520
  static let settingsWidth: CGFloat = 720
  static let readingWidth: CGFloat = 920
  enum CollectionLayout {
    static let readingWidth: CGFloat = 760
  }
  #if os(macOS)
    static let controlHeight: CGFloat = 40
    static let rowMinimum: CGFloat = 36
    // Plain macOS lists retain an 8-point selection gutter even with zero row
    // insets. Compensate once in the native adapter, never in feature pages.
    static let nativeListInset: CGFloat = 8
  #else
    static let controlHeight: CGFloat = 44
    static let rowMinimum: CGFloat = 44
    static let nativeListInset: CGFloat = 0
  #endif
  static let gap: CGFloat = Space.group
  static let radius: CGFloat = 12
  static let fieldRadius: CGFloat = 10
  enum Typography {
    static let detailTitle = Font.title2.weight(.semibold)
    static let title = Font.title3.weight(.semibold)
    static let control = Font.subheadline
    static let body = Font.body
  }
  static var fieldBackground: Color { Color.primary.opacity(0.035) }
  static var selectionBackground: Color { Color.accentColor.opacity(0.09) }
  static var canvas: Color {
    #if os(macOS)
      Color(nsColor: .controlBackgroundColor)
    #else
      Color(uiColor: .systemBackground)
    #endif
  }
  static var line: Color { Color.primary.opacity(0.07) }
}

/// Give the trigger an icon without applying an icon-only style to the menu rows.
struct WorkspaceMoreMenu<Content: View>: View {
  var title = "更多"
  @ViewBuilder var content: Content

  var body: some View {
    Menu {
      content.labelStyle(.titleAndIcon)
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel(title)
  }
}

struct WorkspaceFilters<Value: Hashable>: View {
  let values: [Value]
  @Binding var selection: Value
  let title: (Value) -> String
  var count: ((Value) -> Int)?
  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Button {
          selection = value
        } label: {
          HStack(spacing: 5) {
            Text(title(value))
            if let n = count?(value), n > 0 {
              Text(n.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
          }
          .font(.subheadline.weight(selection == value ? .medium : .regular))
          .padding(.horizontal, 10).padding(.vertical, 7)
          .foregroundStyle(selection == value ? Color.accentColor : .secondary)
          .background(
            selection == value ? WorkbenchDesign.selectionBackground : .clear,
            in: .rect(cornerRadius: 7)
          )
          .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("filter." + title(value))
          .accessibilityAddTraits(selection == value ? .isSelected : [])
      }
    }.fixedSize(horizontal: true, vertical: false)
  }
}

struct WorkspaceSearch: View {
  let prompt: String
  @Binding var text: String
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
      TextField(prompt, text: $text).textFieldStyle(.plain)
      if !text.isEmpty {
        Button("清除搜索", systemImage: "xmark.circle.fill") { text = "" }.labelStyle(.iconOnly)
          .buttonStyle(.plain).foregroundStyle(.tertiary)
      }
    }.font(WorkbenchDesign.Typography.control).padding(.horizontal, 10).padding(.vertical, 8)
      .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 8))
  }
}

struct WorkspacePanel<Content: View>: View {
  let title: String
  let symbol: String
  let add: () -> Void
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 7) {
        Image(systemName: symbol).foregroundStyle(.secondary)
        Text(title).font(.headline)
        Spacer()
        Button("添加" + title, systemImage: "plus") { add() }.labelStyle(.iconOnly).buttonStyle(
          .borderless)
      }
      content
    }.frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct WorkspaceMasterHeader<Filters: View>: View {
  let prompt: String
  @Binding var search: String
  @ViewBuilder var filters: Filters
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      WorkspaceSearch(prompt: prompt, text: $search)
      filters
    }.padding(WorkbenchDesign.masterInset)
  }
}

/// Owns list insets and separator geometry. Pages never rely on a platform's
/// inferred label alignment, which can put a separator underneath trailing actions.
struct WorkspaceList<Content: View>: View {
  var selection: Binding<String?>? = nil
  var inset: CGFloat = WorkbenchDesign.pageInset
  @ViewBuilder var content: Content
  var body: some View {
    Group {
      if let selection {
        List(selection: selection) { rows }
      } else {
        List { rows }
      }
    }
    .listStyle(.plain).scrollContentBackground(.hidden)
    .font(WorkbenchDesign.Typography.body)
    .environment(\.defaultMinListRowHeight, WorkbenchDesign.rowMinimum)
    .padding(.horizontal, inset - WorkbenchDesign.nativeListInset)
    .background(WorkbenchDesign.canvas)
  }
  private var rows: some View {
    content.listRowInsets(EdgeInsets())
      .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
      .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
  }
}

extension View {
  /// Exactly one owner for the outer gutter of composed pages.
  func workspacePage() -> some View {
    self.padding(WorkbenchDesign.pageInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(WorkbenchDesign.canvas)
  }
  func workspaceCard() -> some View {
    self.padding(WorkbenchDesign.Space.section).background(
      WorkbenchDesign.canvas, in: .rect(cornerRadius: WorkbenchDesign.radius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchDesign.radius).strokeBorder(
        WorkbenchDesign.line, lineWidth: 1)
    }
  }
}

/// Small creation sheets have explicit content margins and actions; their size
/// must not be inferred from a single unstyled Form row on macOS.
struct WorkspaceEntrySheet<Content: View>: View {
  let title: String
  var confirmTitle = "保存"
  var saving = false
  let canSave: Bool
  let cancel: () -> Void
  let save: () -> Void
  @ViewBuilder var content: Content
  var body: some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.group) {
        Text(title).font(WorkbenchDesign.Typography.title)
        content
        HStack(spacing: 10) {
          Spacer()
          Button("取消", action: cancel).keyboardShortcut(.cancelAction).disabled(saving)
          Button(confirmTitle, action: save).keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent).disabled(saving || !canSave)
        }.controlSize(.large)
      }.padding(WorkbenchDesign.sheetInset).frame(width: WorkbenchDesign.sheetWidth).fixedSize(
        horizontal: false, vertical: true
      )
      .background(WorkbenchDesign.canvas).interactiveDismissDisabled(saving)
    #else
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: WorkbenchDesign.Space.group) { content }.padding(
            WorkbenchDesign.pageInset)
        }.scrollDismissesKeyboard(.interactively).navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("取消", action: cancel).disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
              Button(confirmTitle, action: save).disabled(saving || !canSave)
            }
          }
      }.interactiveDismissDisabled(saving)
    #endif
  }
}

extension View {
  func workspaceInput(focused: Bool = false) -> some View {
    self.textFieldStyle(.plain).padding(WorkbenchDesign.Space.medium).frame(
      maxWidth: .infinity, minHeight: WorkbenchDesign.controlHeight, alignment: .leading
    )
    .background(
      WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: WorkbenchDesign.fieldRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchDesign.fieldRadius).strokeBorder(
        focused ? Color.accentColor.opacity(0.55) : WorkbenchDesign.line, lineWidth: 1)
    }
  }
  @ViewBuilder func workspaceSheetForm(height: CGFloat) -> some View {
    #if os(macOS)
      self.formStyle(.grouped).frame(width: WorkbenchDesign.formWidth, height: height)
    #else
      self
    #endif
  }
}

/// SwiftUI probes custom layouts with zero, nil and infinity before actual placement.
/// Never propagate an unbounded proposal into native text controls or row geometry.
func finiteLayoutWidth(_ proposed: CGFloat?, fallback: CGFloat) -> CGFloat {
  guard let proposed, proposed.isFinite else { return fallback }
  return min(100_000, max(1, proposed))
}
func finiteLayoutHeight(_ measured: CGFloat, fallback: CGFloat) -> CGFloat {
  measured.isFinite && measured >= 0 ? min(100_000, measured) : fallback
}

/// A composer measures its growing field once and gives the submit button the
/// same height. Native button chrome must not impose a different intrinsic size.
struct WorkspaceComposerLayout: Layout {
  private func dimensions(_ proposal: ProposedViewSize, _ views: Subviews) -> CGSize {
    let width = max(
      WorkbenchDesign.controlHeight * 2, finiteLayoutWidth(proposal.width, fallback: 320))
    let fieldWidth = width - WorkbenchDesign.controlHeight - WorkbenchDesign.Space.small
    let height = views.first?.sizeThatFits(.init(width: fieldWidth, height: nil)).height ?? 0
    return CGSize(
      width: width,
      height: max(
        WorkbenchDesign.controlHeight,
        finiteLayoutHeight(height, fallback: WorkbenchDesign.controlHeight)))
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    dimensions(proposal, subviews)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 2 else { return }
    let fieldWidth = bounds.width - WorkbenchDesign.controlHeight - WorkbenchDesign.Space.small
    subviews[0].place(
      at: bounds.origin, anchor: .topLeading,
      proposal: .init(width: fieldWidth, height: bounds.height))
    subviews[1].place(
      at: .init(x: bounds.maxX - WorkbenchDesign.controlHeight, y: bounds.minY),
      anchor: .topLeading,
      proposal: .init(width: WorkbenchDesign.controlHeight, height: bounds.height))
  }
}

struct WorkspaceSubmitButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.body.weight(.medium))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(enabled ? Color.white : Color.secondary)
      .background(
        enabled ? Color.accentColor : WorkbenchDesign.fieldBackground,
        in: .rect(cornerRadius: WorkbenchDesign.fieldRadius)
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(.rect(cornerRadius: WorkbenchDesign.fieldRadius))
  }
}

/// Reading details use section spacing instead of a separator under every label.
struct WorkspaceDetailPage<Content: View>: View {
  var width: CGFloat = WorkbenchDesign.readingWidth
  @ViewBuilder var content: Content
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkbenchDesign.Space.group) { content }
        .padding(WorkbenchDesign.pageInset)
        .frame(maxWidth: width, alignment: .leading)
        .frame(maxWidth: .infinity)
    }.background(WorkbenchDesign.canvas).scrollDismissesKeyboard(.interactively)
  }
}

/// Shared reading sections: one heading, consistent spacing and a quiet boundary.
struct WorkspaceDetailSection<Content: View>: View {
  let title: String
  var count: Int? = nil
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      HStack(spacing: WorkbenchDesign.Space.small) {
        Text(title).font(.headline)
        if let count { Text(count.formatted()).font(.subheadline).foregroundStyle(.secondary) }
      }
      content
    }.frame(maxWidth: .infinity, alignment: .leading).workspaceCard()
  }
}

struct OptionalDateField: View {
  @Binding var value: String
  var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      Toggle("截止日期", isOn: Binding(get: { !value.isEmpty }, set: { value = $0 ? Clock.day() : "" }))
      if !value.isEmpty {
        Group {
          if expanded {
        DatePicker(
          "选择日期",
          selection: Binding(
            get: { (try? Clock.parse(value + "T00:00:00+08:00")) ?? .now },
            set: { value = Clock.day($0) }), displayedComponents: .date
        )
          .datePickerStyle(.graphical).labelsHidden()
          } else {
        WorkspaceDateField(
          title: "选择日期",
          selection: Binding(
            get: { (try? Clock.parse(value + "T00:00:00+08:00")) ?? .now },
            set: { value = Clock.day($0) })
        )
          }
        }
        .accessibilityIdentifier("order.date.picker")
      }
    }.environment(\.timeZone, Clock.calendar.timeZone).environment(\.calendar, Clock.calendar)
  }
}
struct PhoneCreateModifier: ViewModifier {
  let title: String
  var identifier: String?
  var enabled: Bool
  let action: () -> Void
  func body(content: Content) -> some View {
    #if os(iOS)
      content.safeAreaInset(edge: .bottom, spacing: 0) {
        HStack {
          Spacer()
          Button(title, systemImage: "plus", action: action)
            .accessibilityIdentifier(identifier ?? "create." + title)
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!enabled)
        }.padding(.horizontal, WorkbenchDesign.pageInset).padding(
          .vertical, WorkbenchDesign.Space.small)
      }
    #else
      content
    #endif
  }
}
extension View {
  func phoneCreateAction(
    _ title: String, identifier: String? = nil, enabled: Bool = true, action: @escaping () -> Void
  )
    -> some View
  {
    modifier(
      PhoneCreateModifier(title: title, identifier: identifier, enabled: enabled, action: action))
  }
}

private struct WorkspaceKeyboardDone: ViewModifier {
  let active: Bool
  let done: () -> Void
  func body(content: Content) -> some View {
    #if os(iOS)
      content.toolbar {
        if active {
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成", action: done).accessibilityIdentifier("keyboard.done")
          }
        }
      }
    #else
      content
    #endif
  }
}
extension View {
  func workspaceKeyboardDone(when active: Bool, done: @escaping () -> Void) -> some View {
    modifier(WorkspaceKeyboardDone(active: active, done: done))
  }
}

// Root tabs have no empty navigation bar; destinations explicitly restore the
// system back path and editing actions, including item-bound destinations.
extension View {
  func phoneDetailNavigation() -> some View {
    #if os(iOS)
      self.navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
    #else
      self
    #endif
  }
  func workspaceSettingsForm() -> some View {
    #if os(iOS)
      self.formStyle(.grouped)
        .contentMargins(.top, WorkbenchDesign.Space.small, for: .scrollContent)
        .listSectionSpacing(WorkbenchDesign.Space.group)
    #else
      self.formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: WorkbenchDesign.settingsWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchDesign.canvas)
    #endif
  }
}
