import Foundation
import Observation

@MainActor @Observable public final class WorkspaceStore {
  public private(set) var snapshot = WorkspaceSnapshot()
  public let database: WorkspaceDatabase
  public init(database: WorkspaceDatabase) { self.database = database }
  @ObservationIgnored var didRefresh: (@MainActor () async -> Void)?
  public func refresh() async throws {
    snapshot = try await database.snapshot()
    await didRefresh?()
  }
  @discardableResult public func perform(_ command: WorkspaceCommand) async throws -> CommandResult
  {
    let result = try await database.perform(command)
    try await refresh()
    return result
  }
}
@MainActor @Observable public final class PhotoStore {
  public private(set) var snapshot = PhotoSnapshot()
  public let database: PhotoDatabase
  public init(database: PhotoDatabase) { self.database = database }
  public func refresh() async throws { snapshot = try await database.snapshot() }
  @discardableResult public func perform(_ command: PhotoCommand) async throws -> CommandResult {
    let result = try await database.perform(command)
    try await refresh()
    return result
  }
}
@MainActor @Observable public final class AppSession {
  public let role: AppRole
  public private(set) var workspace: WorkspaceStore?
  public private(set) var photos: PhotoStore?
  public private(set) var location: DataLocation?
  public private(set) var isLoading = false
  public var error: String?
  public var syncMessage = ""
  public var backupStatus = ""
  public private(set) var syncing = false
  public var foundSpaces: [JSONValue] = []
  let thoughtEditing = ThoughtEditing()
  @ObservationIgnored let reminders = WorkspaceReminders()
  var taskReminderIssue: String? { reminders.issue }
  @ObservationIgnored private var lease: WriterLease?
  @ObservationIgnored let cloud = CloudService()
  @ObservationIgnored private var pendingSync: Task<Void, Never>?
  @ObservationIgnored private var syncRequested = false
  #if os(macOS)
    @ObservationIgnored var assistantBridge: AssistantBridge?
    let weChatAssistant = WeChatAssistant()
  #endif
  #if os(iOS)
    @ObservationIgnored private var focusActivity: FocusLiveActivity?
  #endif
  public var focusStatus: FocusPresentation? {
    workspace.flatMap { FocusPresentation.current(in: $0.snapshot) }
  }
  public var focusSurfaceNotice: String? {
    #if os(iOS)
      focusActivity?.notice
    #else
      nil
    #endif
  }
  public init(role: AppRole) {
    self.role = role
    thoughtEditing.didSave = { [weak self] in self?.scheduleSync() }
    #if os(iOS)
      if role == .workbench { focusActivity = FocusLiveActivity() }
    #endif
  }
  public func refreshFocusSurfaces() async {
    #if os(iOS)
      await focusActivity?.reconcile(focusStatus)
    #endif
  }
  public func start() async {
    guard photos == nil && !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let location = try DataLocation.current(role: role)
      let lease = try await Task.detached { try MigrationSafety.prepare(location) }.value
      // The assistant never constructs a WorkspaceDatabase, even during migration.
      let personal: WorkspaceStore?
      if role == .workbench {
        personal = WorkspaceStore(database: try WorkspaceDatabase(url: location.workspaceURL))
        try await personal?.refresh()
      } else {
        personal = nil
      }
      let photos = PhotoStore(database: try PhotoDatabase(url: location.photoURL))
      try await photos.refresh()
      self.lease = lease
      self.location = location
      self.workspace = personal
      personal?.didRefresh = { [weak self] in
        await self?.refreshFocusSurfaces()
        await self?.refreshWorkspaceReminders()
      }
      self.photos = photos
      await refreshFocusSurfaces()
      error = nil
      #if os(macOS)
        if let personal {
          startAssistantBridge(personal)
          weChatAssistant.configure(session: self, store: personal, directory: location.directory)
        }
      #endif
      if role == .workbench { await refreshWorkspaceReminders(force: true) }
    } catch { self.error = error.localizedDescription }
  }
  public func run(_ body: @escaping @MainActor () async throws -> Void) {
    Task {
      do {
        try await body()
        scheduleSync()
      } catch { self.error = error.localizedDescription }
    }
  }
  public func scheduleSync() {
    pendingSync?.cancel()
    pendingSync = Task {
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      pendingSync = nil
      await sync()
    }
  }
  public func sync() async {
    guard let photos, let location else { return }
    guard !syncing else { syncRequested = true; return }
    syncing = true
    defer {
      syncing = false
      if syncRequested { syncRequested = false; scheduleSync() }
    }
    syncMessage = "正在同步"
    do {
      let identity = try await cloud.exchange(.object(["operation": .string("identity")]))
      guard identity["enabled"].bool else {
        syncMessage = "仅本机"
        return
      }
      try await syncIndependentScopes(workspace: {
        if let workspace {
          do {
            try await syncWorkspace(
              workspace.database, identity: identity, directory: location.directory)
          } catch {
            try? await workspace.refresh()
            throw error
          }
          try await workspace.refresh()
          if try await workspace.database.syncSetting("drive.enabled") != .string("0"),
            try await workspace.database.syncSetting("drive.staged_day") != .string(Clock.day())
          {
            do {
              try await backupToDrive()
              backupStatus = "历史备份已保存"
            } catch { backupStatus = error.localizedDescription }
          }
        }
      }, photos: {
        if photos.snapshot.workspace.isNull {
          let found = try await cloud.exchange(
            .object(["operation": .string("photo.discover"), "account": identity["account"]]))
          foundSpaces = found["workspaces"].array
          if foundSpaces.count == 1 {
            try await photos.database.bind(foundSpaces[0])
            try await photos.database.setSetting("token", value: .null)
          }
        }
        let space = try await photos.database.setting("workspace")
        if !space.isNull {
          try await syncPhotos(
            photos.database, space: space, identity: identity, directory: location.directory)
        }
        try await photos.refresh()
      })
      let hasConflicts = !(workspace?.snapshot.conflicts.isEmpty ?? true)
        || !photos.snapshot.conflicts.isEmpty
      syncMessage = hasConflicts ? "有修改待核对" : "已同步"
    } catch {
      syncMessage = error.localizedDescription
      try? await photos.refresh()
    }
  }
  public func connectPhotos(
    create: Bool = false, invitation: String? = nil, selected: JSONValue? = nil
  ) async throws {
    guard let photos else { throw WorkBenchError("拍照数据尚未加载") }
    let identity = try await cloud.exchange(.object(["operation": .string("identity")]))
    try require(identity["enabled"].bool, "请用已签名的 App 登录 iCloud")
    if let selected {
      try await photos.database.bind(selected)
    } else if let invitation {
      var packet: JSONValue = .object([
        "operation": .string("photo.join"), "account": identity["account"],
        "url": .string(invitation),
      ])
      let existing = try await photos.database.setting("workspace")
      if !existing.isNull { packet["expectedWorkspace"] = existing }
      let result = try await cloud.exchange(packet)
      try await photos.database.bind(result["workspace"])
    } else {
      let result = try await cloud.exchange(
        .object(["operation": .string("photo.discover"), "account": identity["account"]]))
      foundSpaces = result["workspaces"].array
      if foundSpaces.count == 1 {
        try await photos.database.bind(foundSpaces[0])
      } else if create {
        try require(foundSpaces.isEmpty, "已有多个空间，请先选择已有空间")
        var zone = try await photos.database.setting("pending_zone")
        if zone.isNull {
          zone = .string("PhotoWorkspace_" + UUID().uuidString.lowercased())
          try await photos.database.setSetting("pending_zone", value: zone)
        }
        let result = try await cloud.exchange(
          .object([
            "operation": .string("photo.create"), "account": identity["account"], "zone": zone,
          ]))
        try await photos.database.bind(result["workspace"])
      }
    }
    try await photos.database.setSetting("token", value: .null)
    try await photos.refresh()
    await sync()
  }
  public func invitation(email: String) async throws -> String {
    guard let photos else { throw WorkBenchError("拍照数据尚未加载") }
    let identity = try await cloud.exchange(.object(["operation": .string("identity")]))
    let space = try await photos.database.setting("workspace")
    try checkIdentity(space, identity)
    let result = try await cloud.exchange(
      .object([
        "operation": .string("photo.invite"), "account": identity["account"], "workspace": space,
        "email": .string(email),
      ]))
    return result["url"].string
  }
  private func checkIdentity(_ space: JSONValue, _ identity: JSONValue) throws {
    try require(
      ["account", "container", "environment"].allSatisfy { space[$0] == identity[$0] },
      "iCloud 账号或环境已改变，原空间同步暂停")
  }
  private func documents(_ value: JSONValue) throws -> [SyncDocument] {
    try JSONDecoder().decode([SyncDocument].self, from: value.data())
  }
  private func syncWorkspace(_ db: WorkspaceDatabase, identity: JSONValue, directory: URL)
    async throws
  {
    let scope = identity["container"].string + "#" + identity["environment"].string
    try await db.bindCloud(container: scope, account: identity["account"].string)
    var token = try await db.syncSetting("cloud.token")
    var expired = false
    while true {
      let result = try await cloud.exchange(
        .object([
          "operation": .string("pull"), "account": identity["account"], "token": token,
          "assetDirectory": .string(directory.appendingPathComponent("attachments").path),
        ]))
      if result["expired"].bool {
        try require(!expired, "同步游标失效，请重试")
        token = .null
        expired = true
        continue
      }
      try await db.receive(documents(result["documents"]))
      token = result["token"]
      try await db.setSyncSetting("cloud.token", value: token)
      if !result["more"].bool { break }
    }
    let pending = try await db.pendingDocuments()
    if !pending.isEmpty {
      let result = try await cloud.exchange(
        .object([
          "operation": .string("push"), "account": identity["account"],
          "assetDirectory": .string(directory.appendingPathComponent("attachments").path),
          "documents": .array(try pending.map { try $0.value() }),
        ]))
      for ack in result["acks"].array {
        let doc = try JSONDecoder().decode(SyncDocument.self, from: ack["pending"].data())
        try await db.acknowledge(doc, serverFields: ack["serverFields"].string)
      }
      try await db.receive(documents(result["conflicts"].isNull ? .array([]) : result["conflicts"]))
      if !result["error"].string.isEmpty { throw WorkBenchError(result["error"].string) }
    }
    try await db.setSyncSetting("cloud.last_success", value: .string(Clock.stamp()))
  }
  private func syncPhotos(
    _ db: PhotoDatabase, space: JSONValue, identity: JSONValue, directory: URL
  ) async throws {
    try checkIdentity(space, identity)
    var token = try await db.setting("token")
    var expired = false
    func packet(_ operation: String) -> JSONValue {
      .object([
        "operation": .string("photo." + operation), "account": identity["account"],
        "workspace": space,
        "assetDirectory": .string(directory.appendingPathComponent("photo-attachments").path),
      ])
    }
    while true {
      var request = packet("pull")
      request["token"] = token
      let result = try await cloud.exchange(request)
      if result["revoked"].bool { try await db.setSetting("locked", value: .bool(true)) }
      if !result["error"].string.isEmpty { throw WorkBenchError(result["error"].string) }
      if result["expired"].bool {
        try require(!expired, "拍照同步游标失效，请重试")
        token = .null
        expired = true
        continue
      }
      try await db.receive(documents(result["documents"]))
      token = result["token"]
      try await db.setSetting("token", value: token)
      if !result["more"].bool { break }
    }
    let pending = try await db.pendingDocuments()
    if !pending.isEmpty {
      var request = packet("push")
      request["documents"] = .array(try pending.map { try $0.value() })
      let result = try await cloud.exchange(request)
      for ack in result["acks"].array {
        let doc = try JSONDecoder().decode(SyncDocument.self, from: ack["pending"].data())
        try await db.acknowledge(doc, serverFields: ack["serverFields"].string)
      }
      try await db.receive(documents(result["conflicts"].isNull ? .array([]) : result["conflicts"]))
      if !result["error"].string.isEmpty { throw WorkBenchError(result["error"].string) }
    }
    try await db.setSetting("last_sync", value: .string(Clock.stamp()))
  }
}
