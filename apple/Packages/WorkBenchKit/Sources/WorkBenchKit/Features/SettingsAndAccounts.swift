import SwiftUI
import UniformTypeIdentifiers

struct JSONDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
struct SettingsView: View {
  @Environment(AppSession.self) private var session
  @State private var document: JSONDocument?
  @State private var exporting = false
  @State private var importing = false
  @State private var driveEnabled = true
  @State private var backupMessage = ""
  @State private var lastBackup = ""
  var body: some View {
    Form {
      #if os(iOS)
        Section("同步与共享") {
          LabeledContent {
            if session.syncing { ProgressView().controlSize(.small) }
            else { Text(syncSummary).foregroundStyle(.secondary) }
          } label: {
            Label("iCloud 同步", systemImage: "icloud")
          }
          Button {
            Task { await session.sync() }
          } label: {
            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
          }.disabled(session.syncing).accessibilityIdentifier("settings.sync")
          NavigationLink {
            PhotoConnectionView().navigationTitle("拍照共享").phoneDetailNavigation()
          } label: {
            Label("拍照共享空间", systemImage: "person.2")
          }.accessibilityIdentifier("settings.photoSharing")
          if !session.syncMessage.isEmpty && syncSummary == "需要重试" {
            Text(session.syncMessage).font(.footnote).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      #endif
      if session.role == .workbench {
        Section("备份与数据") {
          #if os(iOS)
            Toggle("iCloud 云盘历史备份", isOn: $driveEnabled).onChange(of: driveEnabled) { _, value in
              session.run {
                try await session.workspace?.database.setSyncSetting(
                  "drive.enabled", value: .string(value ? "1" : "0"))
              }
            }
            Button("立即备份到云盘", systemImage: "icloud.and.arrow.up") {
              session.run {
                try await session.backupToDrive()
                backupMessage = "历史备份已保存"
              }
            }
          #endif
          Button("导出工作区", systemImage: "square.and.arrow.up") {
            session.run {
              guard let db = session.workspace?.database else { return }
              document = JSONDocument(data: try await db.exportDocument().data())
              exporting = true
            }
          }
          Button("导入备份", systemImage: "square.and.arrow.down") { importing = true }
          if !backupMessage.isEmpty || !session.backupStatus.isEmpty {
            Text(backupMessage.isEmpty ? session.backupStatus : backupMessage).font(.footnote)
              .foregroundStyle(.secondary)
          }
          if !lastBackup.isEmpty { LabeledContent("最近备份", value: lastBackup) }
        }
        Section {
          NavigationLink {
            Form {
              Section {
                LabeledContent(
                  "版本",
                  value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "")
              }
              if let location = session.location {
                Section("本地数据位置") {
                  Text(location.directory.path).font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
              }
            }.workspaceSettingsForm().navigationTitle("关于与存储").phoneDetailNavigation()
          } label: {
            Label("关于与存储", systemImage: "info.circle")
          }
        }
        if let conflicts = session.workspace?.snapshot.conflicts, !conflicts.isEmpty {
          Section("待核对的修改") {
            Text("相同内容已自动合并。展开下面的修改即可比较并选择要保留的内容。")
              .font(.footnote).foregroundStyle(.secondary)
            ForEach(session.workspace?.snapshot.conflicts ?? []) { conflict in
              WorkspaceConflictReview(conflict: conflict)
            }
          }
        }
      }
      if let photos = session.photos, !photos.snapshot.conflicts.isEmpty {
        Section("拍照共享冲突") {
          Text("本机与共享空间对同一内容有不同修改。请展开比较后选择要保留的内容，核对完成后再同步。")
            .font(.footnote).foregroundStyle(.secondary)
          ForEach(photos.snapshot.conflicts) { PhotoConflictReview(conflict: $0) }
        }
      }
    }.workspaceSettingsForm().accessibilityIdentifier("settings.form")
      .fileExporter(
        isPresented: $exporting, document: document, contentType: .json,
        defaultFilename: "WorkBench-" + Clock.day()
      ) { result in
        if case .failure(let error) = result { session.error = error.localizedDescription }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        session.run {
          guard let db = session.workspace?.database else { return }
          let url = try result.get()
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let document = try await Task.detached { try JSONValue(data: Data(contentsOf: url)) }
            .value
          let count = try await db.importDocument(document)
          try await session.workspace?.refresh()
          backupMessage = "已导入 \(count) 条记录"
        }
      }
      .task {
        if let value = try? await session.workspace?.database.syncSetting("drive.last_saved"),
          let date = try? Clock.parse(value.string)
        {
          lastBackup = date.formatted(.dateTime.month().day().hour().minute())
        }
        driveEnabled =
          (try? await session.workspace?.database.syncSetting("drive.enabled")) != .string("0")
      }
  }
  private var syncSummary: String {
    if session.syncing { return "正在同步" }
    switch session.syncMessage {
    case "": return "尚未同步"
    case "已同步", "仅本机", "有修改待核对": return session.syncMessage
    default: return "需要重试"
    }
  }
}
struct AccountsView: View {
  @Environment(AppSession.self) private var session
  @State private var adding = false
  @State private var search = ""
  @State private var dataAccount: WorkspaceItem?
  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.section) {
      WorkspaceSearch(prompt: "搜索账号", text: $search).frame(maxWidth: 320)
      WorkspaceList(inset: 0) {
        ForEach(
          (session.workspace?.snapshot[.accounts] ?? []).filter {
            search.isEmpty || $0.fields.text("name").localizedCaseInsensitiveContains(search)
          }
        ) { account in
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              PlatformLogo(platform: account[.platform].string)
              InlineItemText(account.fields.text("name")) {
                _ = try await session.workspace?.perform(
                  .update(.accounts, id: account.id, fields: [.name: .string($0)]))
              }
              Spacer()
              #if os(macOS)
                Button("打开后台", systemImage: "arrow.up.right.square") {
                  session.run {
                    guard let directory = session.location?.directory else { return }
                    try await ChromeService.shared.operate(
                      .open, account: account, directory: directory)
                  }
                }
              #endif
              Menu("更多", systemImage: "ellipsis") {
                #if os(macOS)
                  Button("重新登录", systemImage: "arrow.clockwise") {
                    session.run {
                      guard let directory = session.location?.directory else { return }
                      try await ChromeService.shared.operate(
                        .reset, account: account, directory: directory)
                    }
                  }
                #endif
                Button("删除账号", systemImage: "trash", role: .destructive) {
                  session.run {
                    #if os(macOS)
                      if let directory = session.location?.directory {
                        try await ChromeService.shared.operate(
                          .retire, account: account, directory: directory)
                      }
                    #endif
                    _ = try await session.workspace?.perform(.delete(.accounts, id: account.id))
                  }
                }
              }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
              Button("查看作品数据", systemImage: "chart.xyaxis.line") { dataAccount = account }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("作品数据")
            }
          }.padding(.vertical, WorkbenchDesign.rowInset)
        }
      }
    }.workspacePage().toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("添加账号", systemImage: "plus") { adding = true }
      }
    }
    .sheet(isPresented: $adding) { NewAccountView() }
    .sheet(item: $dataAccount) { account in
      NavigationStack {
        AccountMetricsView(account: account).toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("关闭") { dataAccount = nil } }
        }
      }
    }
  }
}
struct PlatformLogo: View {
  let platform: String
  var body: some View {
    Image(platform, bundle: .module).resizable().scaledToFit().frame(width: 24, height: 24)
      .accessibilityHidden(true)
  }
}
struct NewAccountView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var platform = "douyin"
  @State private var saving = false
  @FocusState private var focused: Bool
  let platforms = [
    ("douyin", "抖音"), ("bilibili", "哔哩哔哩"), ("xiaohongshu", "小红书"), ("x", "X"),
    ("tiktok", "TikTok"), ("instagram", "Instagram"), ("youtube", "YouTube"),
  ]
  var body: some View {
    WorkspaceEntrySheet(
      title: "添加账号", confirmTitle: "添加", saving: saving,
      canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      cancel: { dismiss() }, save: save
    ) {
      TextField("账号名称", text: $name).focused($focused).labelsHidden()
        .workspaceInput(focused: focused)
      Picker("平台", selection: $platform) {
        ForEach(platforms, id: \.0) { Text($0.1).tag($0.0) }
      }
    }.onAppear { focused = true }
  }
  private func save() {
    guard !saving, let store = session.workspace,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    saving = true
    session.run {
      defer { saving = false }
      _ = try await store.perform(
        .create(.accounts, fields: [.name: .string(name), .platform: .string(platform)]))
      dismiss()
    }
  }
}
extension AppSession {
  public func backupToDrive() async throws {
    guard role == .workbench, let db = workspace?.database, let directory = location?.directory
    else { throw WorkBenchError("拍照助手不能导出个人工作区") }
    let document = try await db.exportDocument()
    let assets = workspace?.snapshot[.attachments] ?? []
    let name =
      "workbench-native-" + Clock.stamp().replacingOccurrences(of: ":", with: "-") + "-"
      + UUID().uuidString.prefix(8) + ".json"
    let folder = directory.appendingPathComponent("backups/icloud-drive", isDirectory: true)
    try await Task.detached {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try document.data().write(to: folder.appendingPathComponent(name), options: .atomic)
    }.value
    let identity = try await db.syncSetting("drive.identity")
    let result = try await CloudDocumentsService().exchange(
      .object([
        "operation": .string("write"), "name": .string(name),
        "document": .string(try document.json()), "identity": identity,
        "assets": .array(
          assets.map { item in
            .object([
              "key": item.fields[value: "file_key"],
              "path": .string(
                directory.appendingPathComponent("attachments/" + item.fields.text("file_key")).path
              ),
            ])
          }),
      ]))
    try await db.setSyncSetting("drive.identity", value: result["identity"])
    try await db.setSyncSetting("drive.last_name", value: .string(name))
    try await db.setSyncSetting("drive.last_saved", value: .string(Clock.stamp()))
    try await db.setSyncSetting("drive.staged_day", value: .string(Clock.day()))
  }
}
