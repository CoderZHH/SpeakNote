import Foundation

public enum AppRole: String, Sendable { case workbench, photoAssistant }
public enum WorkspaceEntity: String, Codable, CaseIterable, Sendable {
  case semesters, courses
  case courseMeetings = "course_meetings"
  case projects, learning, notes, reflections, tasks, lessons, accounts, metrics
  case focusSessions = "focus_sessions"
  case focusIntervals = "focus_intervals"
  case attachments
}
public enum ItemField: String, Sendable, Hashable {
  case title, content, notes, remark, description, status, color, tags, day, teacher, code, name,
    platform, estimate, importance, important, priority
  case plannedDate = "planned_date"
  case dueDate = "due_date"
  case startTime = "start_time"
  case endTime = "end_time"
  case reminderEnabled = "reminder_enabled"
  case reminderAt = "reminder_at"
  case projectID = "project_id"
  case learningID = "learning_id"
  case courseID = "course_id"
  case sourceNoteID = "source_note_id"
  case parentID = "parent_id"
  case repoPath = "repo_path"
  case semesterID = "semester_id"
  case firstMonday = "first_monday"
  case weeks, periods, weekday
  case periodStart = "period_start"
  case periodEnd = "period_end"
  case room, done
  case taskID = "task_id"
  case position
}
public struct WorkspaceItem: Identifiable, Sendable, Equatable {
  public let entity: WorkspaceEntity
  let fields: Record
  public var id: String { fields.identifier }
  public var title: String {
    fields.text("title").isEmpty ? fields.text("content") : fields.text("title")
  }
  public var status: String { fields.text("status") }
  public var importance: Int { max(1, min(5, Int(fields.integer("importance")))) }
  public var createdAt: String { fields.text("created_at") }
  public subscript(_ field: ItemField) -> JSONValue { fields[field.rawValue] ?? .null }
}
public struct WorkspaceSnapshot: Sendable {
  public var items: [WorkspaceEntity: [WorkspaceItem]] = [:]
  public var conflicts: [SyncConflict] = []
  public var pending: Int = 0
  public subscript(_ entity: WorkspaceEntity) -> [WorkspaceItem] { items[entity] ?? [] }
  public func item(_ entity: WorkspaceEntity, _ id: String) -> WorkspaceItem? {
    self[entity].first { $0.id == id }
  }
  public func association(_ item: WorkspaceItem) -> WorkspaceItem? {
    for (field, entity) in [
      (ItemField.projectID, WorkspaceEntity.projects), (.learningID, .learning),
      (.courseID, .courses),
    ] { if let linked = self.item(entity, item[field].string) { return linked } }
    return nil
  }
}
public enum MovePlacement: String, Sendable { case before, after, inside }
public struct ThoughtContentVersion: Equatable, Sendable {
  public let text: String
  public let tags: [String]
  public init(text: String, tags: [String]) { self.text = text; self.tags = tags }
  init(fields: Record) {
    text = fields.text("content")
    tags = (try? JSONValue(json: fields.text("tags")).array.map(\.string)) ?? []
  }
}
struct ThoughtSaveConflict: LocalizedError {
  let saved: ThoughtContentVersion
  var errorDescription: String? { "这篇思考有不同的已保存版本。你的输入已保留。" }
}
public enum WorkspaceConflictChoice: Sendable { case current, saved, keepBoth }
public enum WorkspaceCommand: Sendable {
  case create(
    WorkspaceEntity, id: String = UUID().uuidString.lowercased(), fields: [ItemField: JSONValue])
  case update(
    WorkspaceEntity, id: String, fields: [ItemField: JSONValue], expectedUpdatedAt: String? = nil,
    expectedThought: ThoughtContentVersion? = nil)
  case delete(WorkspaceEntity, id: String)
  case convertNote(id: String, plannedDate: String?)
  case scheduleLesson(id: String, plannedDate: String)
  case startFocus(taskID: String?)
  case pauseFocus
  case endFocus(id: String, resumeHint: String?)
  case correctFocus(id: String, intervalID: String?, start: Date, end: Date)
  case move(
    WorkspaceEntity, id: String, targetEntity: WorkspaceEntity, targetID: String,
    placement: MovePlacement)
  case importMetrics(accountID: String, rows: [MetricInput])
  case installTimetable
  case restoreConflict(id: String)
  case dismissConflict(id: String)
  case resolveConflict(id: String, choice: WorkspaceConflictChoice, expectedRevision: Int64)
}
public struct CommandResult: Sendable {
  public var id: String?
  public var alreadyRunning = false
  var thoughtVersion: ThoughtContentVersion?
}
public struct SyncDocument: Codable, Sendable, Equatable {
  public var entity: String?
  public var id: String
  public var kind: String?
  public var order_id: String?
  public var payload: JSONValue
  public var revision: Int64?
  public var serverFields: String?
  init(
    entity: String? = nil, id: String, kind: String? = nil, orderID: String? = nil,
    payload: JSONValue, revision: Int64? = nil, serverFields: String? = nil
  ) {
    self.entity = entity
    self.id = id
    self.kind = kind
    self.order_id = orderID
    self.payload = payload
    self.revision = revision
    self.serverFields = serverFields
  }
  func value() throws -> JSONValue { try JSONValue(data: JSONEncoder().encode(self)) }
}
public struct SyncConflict: Identifiable, Sendable {
  public let id: String
  public let entity: String
  public let recordID: String
  public let local: JSONValue
  public let remote: JSONValue
  public let revision: Int64
  public var base: JSONValue = .null
}
public enum PhotoStage: String, Codable, CaseIterable, Sendable, Identifiable {
  case output, review, `return`, submit, refund, completed
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .output: "待出图"
    case .review: "待审图"
    case .return: "待寄回"
    case .submit: "待提交"
    case .refund: "待返款"
    case .completed: "已完成"
    }
  }
  public var symbol: String {
    switch self {
    case .output: "camera"
    case .review: "eye"
    case .return: "shippingbox"
    case .submit: "paperplane"
    case .refund: "yensign.circle"
    case .completed: "checkmark.circle"
    }
  }
  public var next: Self? {
    let all = Self.allCases
    let index = all.firstIndex(of: self)!
    return index + 1 < all.count ? all[index + 1] : nil
  }
}
public enum PhotoField: String, CaseIterable, Sendable, Identifiable {
  case brand, requirements, postage, commission, deadline, notes, images
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .brand: "品牌"
    case .requirements: "拍摄要求"
    case .postage: "邮费"
    case .commission: "佣金"
    case .deadline: "截止日期"
    case .notes: "备注"
    case .images: "订单截图"
    }
  }
}
public struct PhotoOrder: Identifiable, Sendable, Equatable {
  let fields: Record
  public var id: String { fields.identifier }
  public var brand: String { fields.text("brand") }
  public var stage: PhotoStage {
    if !fields[value: "workflow"]["completed_at"].isNull { return .completed }
    return PhotoStage(rawValue: fields[value: "workflow"]["stage"].string) ?? .output
  }
  public var images: [String] { fields[value: "images"].array.map(\.string) }
  public var revision: Int64 { fields.integer("revision") }
  public var workflowRevision: Int64 { fields.integer("workflow_revision") }
  public subscript(_ field: PhotoField) -> JSONValue { fields[field.rawValue] ?? .null }
}
public struct PhotoOrderInput: Sendable {
  public var id = UUID().uuidString.lowercased()
  public var creationToken = UUID().uuidString.lowercased()
  public var brand = ""
  public var requirements = ""
  public var postage: Int64?
  public var commission: Int64?
  public var deadline = ""
  public var notes = ""
  public var images: [String] = []
  public var stage: PhotoStage = .output
  public init() {}
  var fields: Record {
    [
      "id": .string(id), "creation_token": .string(creationToken), "brand": .string(brand),
      "requirements": .string(requirements), "postage": postage.map(JSONValue.integer) ?? .null,
      "commission": commission.map(JSONValue.integer) ?? .null, "deadline": .string(deadline),
      "notes": .string(notes), "images": .array(images.map(JSONValue.string)),
    ]
  }
}
public enum PhotoCommand: Sendable {
  case create(PhotoOrderInput)
  case patch(id: String, field: PhotoField, before: JSONValue, value: JSONValue)
  case transition(id: String, stage: PhotoStage, expectedRevision: Int64)
  case delete(id: String, expectedRevision: Int64)
  case resolveConflict(id: String, keepLocal: Bool, expectedRevision: Int64)
}
public struct MediaAttachment: Identifiable, Sendable, Equatable {
  let fields: Record
  public var id: String { fields.identifier }
  public var name: String { fields.text("name") }
  public var mime: String { fields.text("mime") }
  public var fileKey: String { fields.text("file_key") }
  public var hash: String { fields.text("sha256") }
  public var size: Int64 { fields.integer("size") }
}
public struct PhotoSnapshot: Sendable {
  public var orders: [PhotoOrder] = []
  public var attachments: [MediaAttachment] = []
  public var workspace: JSONValue = .null
  public var locked = false
  public var pending = 0
  public var generation: Int64 = 0
  public var lastSync: String?
  public var conflicts: [SyncConflict] = []
  public func order(_ id: String) -> PhotoOrder? { orders.first { $0.id == id } }
}
