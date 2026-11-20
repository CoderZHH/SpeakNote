import Foundation

/// The model schema and the executor share the same list of capabilities.
public enum AssistantContract {
  enum Entity: String, CaseIterable {
    case spaces, collections, semesters, courses
    case courseMeetings = "course_meetings"
    case tasks, notes, projects, learning, memory

    var writableFields: Record {
      let associations = [
        "course_id": optionalString, "project_id": optionalString,
        "learning_id": optionalString, "collection_id": optionalString,
      ]
      switch self {
      case .spaces:
        return [
          "title": string, "symbol": string, "color": string,
          "status": choice(["active", "paused", "done"]),
        ]
      case .collections:
        return [
          "space_id": string, "title": string, "description": string,
          "color": string, "status": choice(["active", "paused", "done"]),
        ]
      case .semesters:
        return [
          "title": string, "first_monday": string, "weeks": integer,
          "periods": array(
            schema(
              ["number": integer, "start": string, "end": string],
              required: ["number", "start", "end"]
            )
          ),
        ]
      case .courses:
        return [
          "semester_id": string, "title": string, "teacher": string,
          "code": string, "description": string, "color": string,
          "status": choice(["active", "paused", "done"]),
        ]
      case .courseMeetings:
        return [
          "course_id": string, "weekday": integer,
          "period_start": integer, "period_end": integer,
          "weeks": array(integer), "room": string,
        ]
      case .tasks:
        return associations.merging([
          "title": string,
          "notes": .object([
            "type": .string("string"),
            "description": .string("任务备注。整理通知或长消息时，把关键信息、步骤和有效链接保存在这里。"),
          ]),
          "status": choice(["todo", "done", "abandoned"]),
          "planned_date": optionalString, "due_date": optionalString, "start_time": optionalString,
          "end_time": optionalString, "reminder_enabled": boolean,
          "reminder_at": .object([
            "type": .array([.string("string"), .string("null")]),
            "description": .string("独立提醒时间，带时区的 ISO 8601，如 2026-11-10T15:00:00+08:00"),
          ]),
          "importance": integer,
        ]) { _, new in new }
      case .notes:
        return associations.merging([
          "content": string, "remark": string, "status": choice(["inbox", "processed", "archived"]),
        ]) { _, new in new }
      case .projects, .learning:
        return ["title": string, "description": string, "status": choice(["active", "paused", "done"])]
      case .memory: return ["content": string]
      }
    }

    var canWriteRecord: Bool { self != .memory && !writableFields.isEmpty }
    var canDeleteRecord: Bool {
      switch self {
      case .tasks, .semesters, .courses, .courseMeetings, .spaces, .collections, .notes: true
      default: false
      }
    }

    var label: String {
      switch self {
      case .spaces: "空间"
      case .collections: "卡片"
      case .semesters: "学期"
      case .courses: "课程"
      case .courseMeetings: "上课安排"
      case .tasks: "任务"
      case .notes: "随手记"
      case .projects: "项目"
      case .learning: "学习项"
      case .memory: "偏好"
      }
    }

    var titleColumn: String {
      switch self {
      case .notes, .memory: "content"
      case .courseMeetings: "room"
      default: "title"
      }
    }
  }

  enum Action: String, CaseIterable {
    case create, update, delete, remember, forget
    case startFocus = "start_focus"
    case remindCourse = "remind_course"

    func allows(_ entity: Entity) -> Bool {
      switch self {
      case .create, .update: entity.canWriteRecord
      case .delete: entity.canDeleteRecord
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

  static func writableFieldError(in change: JSONValue) -> String? {
    guard let entity = Entity(rawValue: change["entity"].string) else { return nil }
    let unsupported = Set(change["fields"].object.keys)
      .subtracting(entity.writableFields.keys).sorted()
    guard !unsupported.isEmpty else { return nil }
    let fields = unsupported.prefix(5).map { String($0.prefix(40)) }.joined(separator: "、")
    return "\(entity.label)不支持这些字段：\(fields)。"
  }

  public static var tools: [JSONValue] {
    let changeSchemas = Entity.allCases.map { entity in
      schema([
        "kind": choice(Action.allCases.filter { $0.allows(entity) }.map(\.rawValue)),
        "entity": choice([entity.rawValue]), "target_id": string,
        "expected_version": string, "ref": string, "attach_image": boolean,
        "occurrence_id": string, "minutes_before": integer,
        "fields": schema(entity.writableFields, required: []),
      ], required: ["kind", "entity"])
    }
    return [
      tool(searchTool, """
        查询工作区事项。查询今天的任务用 entity=tasks、task_view=today，按北京时间返回工作台「今日」列表。
        items 包含今天及更早安排的未完成任务，completed_today 是今天实际完成的任务，两组分别提供总数。
        学期用 entity=semesters，课程用 entity=courses（可传 semester_id），具体排课时段用 entity=course_meetings（可传 course_id）。
        用户自定义的板块在 spaces，空间下的卡片在 collections。planned_date 只匹配指定的计划日期。
        用户明确要求缩小范围时才加筛选。普通查询无筛选时列出近期记录。
        """, [
        "entity": choice(Entity.allCases.map(\.rawValue)), "query": string, "status": string,
        "task_view": choice(["today"]),
        "planned_date": string, "space_id": string, "collection_id": string,
        "semester_id": string, "course_id": string, "project_id": string, "learning_id": string,
      ], required: ["entity"]),
      tool(scheduleTool, "查询指定北京时间日期的上课时间、课程和教室。整周以周一为起点。", [
        "date": string, "week": boolean,
      ], required: ["date"]),
      tool(timetableTool, """
        仅生成整套新学期课表的确认预览，不写入记录。只有用户的资料或明确回答足以确定所有必填数据才使用。
        第一周周一是明确的 YYYY-MM-DD，weeks 是学期总周数；节次用 24 小时 HH:mm。
        weekday 为周一=1 至周日=7，weeks 列出具体教学周。没有写明的必填信息先向用户询问。
        如果是管理现有学期（改名、改开学日、删除学期）或增删改单门课程与排课，请先 search_workbench 再用 apply_workbench_changes。
        若用户明确要求替换、覆盖或删除已有旧学期（如「把原来的学期删了」），可在 replace_semester_id 填入该旧学期的 ID，确认时会原子替换并删除旧学期，无需单独调用删除工具。
        """, [
        "replace_semester_id": optionalString,
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
        执行用户明确要求的变更（支持任务、随手记、空间、卡片、学期 semesters、课程 courses、上课安排 course_meetings）。
        修改或删除前必须先查询现有目标，填 target_id 和 expected_version；不明确则问用户。
        新建事项可用 ref 声明批内别名，后续变更可在关联 ID（如 semester_id、course_id、space_id、collection_id）或 target_id 中用 @别名。
        delete 仅删除用户明确指定的事项（删除学期会一并移除其下属课程与排课），必须先查询并提供 target_id 和 expected_version。
        start_focus 可以省略 target_id 开始自由专注。remind_course 用课表返回的 occurrence_id 和 version
        作为 expected_version，并可指定 minutes_before。attach_image=true 把本条消息的图片存到该变更的唯一目标。
        """, [
        "changes": .object(["type": .string("array"), "minItems": .integer(1), "maxItems": .integer(10),
          "items": .object(["anyOf": .array(changeSchemas)])]),
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
