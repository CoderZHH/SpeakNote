import Foundation

struct StagedEntryAttachment: Identifiable, Sendable {
  let fields: Record
  let directory: URL
  var id: String { fields.identifier }
  var name: String { fields.text("name") }
}
actor EntryAttachmentStaging {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "workbench-entry-" + UUID().uuidString)
  private var closed = false
  func add(data: Data, name: String) throws -> StagedEntryAttachment {
    try require(!closed, "新建面板已关闭")
    let fields = try MediaFiles.write(
      data, name: name, directory: directory,
      maximum: 100 * 1024 * 1024, imagesOnly: false)
    return StagedEntryAttachment(fields: fields, directory: directory)
  }
  func remove(_ item: StagedEntryAttachment) throws {
    try MediaFiles.remove(item.fields.text("file_key"), in: directory)
  }
  func discard() {
    closed = true
    try? FileManager.default.removeItem(at: directory)
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
}
