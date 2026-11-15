import Foundation

/// The model schema and the executor share the same list of capabilities.
public enum AssistantContract {
  enum Entity: String, CaseIterable {
    case tasks, notes, projects, learning, courses, memory

    var writableFields: Record {
      let associations = ["course_id": optionalString, "project_id": optionalString, "learning_id": optionalString]
      switch self {
      case .tasks:
        return associations.merging([
          "title": string, "notes": string, "status": choice(["todo", "done", "abandoned"]),
          "planned_date": optionalString, "due_date": optionalString, "start_time": optionalString,
          "end_time": optionalString, "reminder_enabled": boolean,
          "reminder_at": .object(["type": .array([.string("string"), .string("null")]),
            "description": .string("独立提醒时间，带时区的 ISO 8601，如 2026-11-10T15:00:00+08:00")]),
          "importance": integer,
        ]) { _, new in new }
      case .notes:
        return associations.merging([
          "content": string, "remark": string, "status": choice(["inbox", "processed", "archived"]),
        ]) { _, new in new }
      case .projects, .learning:
        return ["title": string, "description": string, "status": choice(["active", "paused", "done"])]
      case .memory: return ["content": string]
      case .courses: return [:]
      }
    }

    var canWriteRecord: Bool { self != .memory && !writableFields.isEmpty }
    var label: String {
      switch self {
      case .tasks: "任务"
      case .notes: "随手记"
      case .projects: "项目"
      case .learning: "学习项"
      case .courses: "课程"
      case .memory: "偏好"
      }
    }

    var titleColumn: String { self == .notes || self == .memory ? "content" : "title" }
  }

  enum Action: String, CaseIterable {
    case create, update, delete, remember, forget
    case startFocus = "start_focus"
    case remindCourse = "remind_course"

    func allows(_ entity: Entity) -> Bool {
      switch self {
      case .create, .update: entity.canWriteRecord
      case .delete: entity == .tasks
      case .remember, .forget: entity == .memory
      case .startFocus: entity == .tasks
      case .remindCourse: entity == .courses
      }
    }
  }

  public static let searchTool = "search_workbench"
  public static let scheduleTool = "course_schedule"
  public static let timetableTool = "preview_timetable_import"
  public static let applyTool = "apply_workbench_changes"

  public static var tools: [JSONValue] {
    let fields = Entity.allCases.reduce(into: Record()) { result, entity in
      result.merge(entity.writableFields) { first, next in first == next ? first : string }
    }
    return [
      tool(searchTool, """
        查询工作区事项。查询今天的任务用 entity=tasks、task_view=today，按北京时间返回工作台「今日」列表。
        items 包含今天及更早安排的未完成任务，completed_today 是今天实际完成的任务，两组分别提供总数。
        planned_date 只匹配指定的计划日期。用户明确要求缩小范围时才加筛选。普通查询无筛选时列出近期记录。
        """, [
        "entity": choice(Entity.allCases.map(\.rawValue)), "query": string, "status": string,
        "task_view": choice(["today"]),
        "planned_date": string, "course_id": string, "project_id": string, "learning_id": string,
      ], required: ["entity"]),
      tool(scheduleTool, "查询指定北京时间日期的上课时间、课程和教室。整周以周一为起点。", [
        "date": string, "week": boolean,
      ], required: ["date"]),
      tool(timetableTool, """
        仅生成新学期课表的确认预览，不写入记录。只有用户的资料或明确回答足以确定所有必填数据才使用。
        第一周周一是明确的 YYYY-MM-DD，weeks 是学期总周数；节次用 24 小时 HH:mm。
        weekday 为周一=1 至周日=7，weeks 列出具体教学周。没有写明的必填信息先向用户询问。
        """, [
        "semester": schema([
          "title": string, "first_monday": string, "weeks": integer,
          "periods": array(schema(["number": integer, "start": string, "end": string],
            required: ["number", "start", "end"])),
        ], required: ["title", "first_monday", "weeks", "periods"]),
        "courses": array(schema([
          "title": string, "teacher": optionalString, "code": optionalString,
          "meetings": array(schema(["weekday": integer, "period_start": integer, "period_end": integer,
            "weeks": array(integer), "room": optionalString],
            required: ["weekday", "period_start", "period_end", "weeks"])),
        ], required: ["title", "meetings"])),
      ], required: ["semester", "courses"]),
      tool(applyTool, """
        执行用户明确要求的变更。先查询现有目标，填 target_id 和 expected_version；不明确则问用户。
        新建项目或学习项可用 ref 声明批内别名，后续变更可在关联 ID 或 target_id 中用 @别名。
        delete 仅删除用户明确指定的任务，必须先查询并提供 target_id 和 expected_version。
        start_focus 可以省略 target_id 开始自由专注。remind_course 用课表返回的 occurrence_id 和 version
        作为 expected_version，并可指定 minutes_before。attach_image=true 把本条消息的图片存到该变更的唯一目标。
        """, [
        "changes": .object(["type": .string("array"), "minItems": .integer(1), "maxItems": .integer(10),
          "items": schema([
            "kind": choice(Action.allCases.map(\.rawValue)),
            "entity": choice(Entity.allCases.map(\.rawValue)), "target_id": string,
            "expected_version": string, "ref": string, "attach_image": boolean,
            "occurrence_id": string, "minutes_before": integer,
            "fields": schema(fields, required: []),
          ], required: ["kind", "entity"])]),
      ], required: ["changes"]),
    ]
  }

  private static var string: JSONValue { .object(["type": .string("string")]) }
  private static var optionalString: JSONValue { .object(["type": .array([.string("string"), .string("null")])]) }
  private static var integer: JSONValue { .object(["type": .string("integer")]) }
  private static var boolean: JSONValue { .object(["type": .string("boolean")]) }
  private static func array(_ items: JSONValue) -> JSONValue {
    .object(["type": .string("array"), "items": items])
  }
  private static func choice(_ values: [String]) -> JSONValue {
    .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
  }
  private static func schema(_ fields: Record, required: [String]) -> JSONValue {
    .object(["type": .string("object"), "properties": .object(fields),
      "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
  }
  private static func tool(_ name: String, _ description: String, _ fields: Record, required: [String]) -> JSONValue {
    .object(["type": .string("function"), "function": .object([
      "name": .string(name), "description": .string(description), "parameters": schema(fields, required: required),
    ])])
  }
}
