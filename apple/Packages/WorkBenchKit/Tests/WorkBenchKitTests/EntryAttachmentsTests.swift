import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import WorkBenchKit

private let entryPNG = Data(
  base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS2kAAAAASUVORK5CYII=")!

@Test @MainActor func remarkPasteImportsImageBytesAndLocalImageFiles() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let imageURL = fixture.directory.appendingPathComponent("课程截图.png")
  try entryPNG.write(to: imageURL)
  let fileProvider = NSItemProvider()
  fileProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { complete in
    complete(imageURL.dataRepresentation, nil)
    return nil
  }
  let file = try #require(try await RemarkImagePaste.load(fileProvider))
  #expect(file.data == entryPNG)
  #expect(file.name == "课程截图.png")

  let bitmap = try #require(CGContext(
    data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  bitmap.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
  bitmap.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
  let image = try #require(bitmap.makeImage())
  let tiff = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  let imageProvider = NSItemProvider()
  let tiffData = tiff as Data
  imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { complete in
    complete(tiffData, nil)
    return nil
  }
  let pasted = try #require(try await RemarkImagePaste.load(imageProvider))
  let pastedSource = try #require(CGImageSourceCreateWithData(pasted.data as CFData, nil))
  #expect(CGImageSourceGetType(pastedSource) as String? == UTType.png.identifier)
  let db = try WorkspaceDatabase(url: fixture.directory.appendingPathComponent("workbench.sqlite"))
  _ = try await db.perform(.installTimetable)
  let course = try #require(try await db.snapshot()[.courses].first)
  let attachment = try await db.importAttachment(data: pasted.data, name: pasted.name, owner: .course(course.id))
  #expect(try await db.snapshot().item(.attachments, attachment.id)?.fields["course_id"] == .string(course.id))
  let linkProvider = NSItemProvider(object: "https://example.com/image.png" as NSString)
  #expect(try await RemarkImagePaste.load(linkProvider) == nil)
}

@Test func newEntryMediaIsAtomicRetryableAndKeepsAssociation() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let db = try WorkspaceDatabase(url: f.directory.appendingPathComponent("workbench.sqlite"))
  let project = try await db.perform(.create(.projects, fields: [.title: .string("媒体项目")])).id!
  for entity in [WorkspaceEntity.tasks, .notes] {
    let staging = EntryAttachmentStaging()
    let first = try await staging.add(data: entryPNG, name: "订单截图.png")
    let second = try await staging.add(data: entryPNG, name: "要求.png")
    let id = UUID().uuidString.lowercased()
    let fields: [ItemField: JSONValue] = [
      entity == .tasks ? .title : .content: .string("带附件的条目"), .projectID: .string(project),
    ]
    // A missing second file must roll back the entry, copied first file and sync journal.
    try FileManager.default.removeItem(
      at: second.directory.appendingPathComponent(second.fields.text("file_key")))
    do {
      try await db.saveEntry(entity: entity, id: id, fields: fields, attachments: [first, second])
      Issue.record("Missing staged file should fail atomically")
    } catch {}
    let failed = try await db.snapshot()
    #expect(failed.item(entity, id) == nil)
    #expect(!failed[.attachments].contains { $0.id == first.id })
    #expect(
      !FileManager.default.fileExists(
        atPath: f.directory.appendingPathComponent("attachments/" + first.fields.text("file_key"))
          .path))
    #expect(try await db.pendingDocuments().allSatisfy { $0.id != id && $0.id != first.id })
    try await db.saveEntry(entity: entity, id: id, fields: fields, attachments: [first])
    try await db.saveEntry(entity: entity, id: id, fields: fields, attachments: [first])
    let saved = try await db.snapshot()
    let item = try #require(saved.item(entity, id))
    #expect(saved.association(item)?.id == project)
    #expect(saved[entity].filter { $0.id == id }.count == 1)
    let attachments = saved[.attachments].filter { $0.id == first.id }
    #expect(attachments.count == 1)
    #expect(attachments.first?.fields[entity == .tasks ? "task_id" : "note_id"] == .string(id))
    let key = first.fields.text("file_key")
    #expect(
      try Data(contentsOf: f.directory.appendingPathComponent("attachments/" + key)) == entryPNG)
    await staging.discard()
    #expect(!FileManager.default.fileExists(atPath: first.directory.path))
  }
}

@Test func cancellingEntryMediaLeavesNoItemAndClosesStaging() async throws {
  let staging = EntryAttachmentStaging()
  let item = try await staging.add(data: entryPNG, name: "截图.png")
  #expect(FileManager.default.fileExists(atPath: item.directory.path))
  await staging.discard()
  #expect(!FileManager.default.fileExists(atPath: item.directory.path))
  do {
    _ = try await staging.add(data: entryPNG, name: "延迟导入.png")
    Issue.record("Closed form must reject delayed imports")
  } catch {}
}

@Test func existingItemAttachmentImportsForAllOwnersAndSurvivesRestart() async throws {
  let f = try Fixture()
  defer { f.clean() }
  let url = f.directory.appendingPathComponent("workbench.sqlite")
  let db = try WorkspaceDatabase(url: url)
  _ = try await db.perform(.installTimetable)
  let course = try await db.snapshot()[.courses][0].id
  var owners: [MediaOwner] = [.course(course)]
  for entity in [WorkspaceEntity.tasks, .notes, .projects, .learning] {
    let id = try await db.perform(
      .create(entity, fields: [entity == .notes ? .content : .title: .string("媒体所属条目")])
    ).id!
    owners.append(
      entity == .tasks
        ? .task(id)
        : entity == .notes ? .note(id) : entity == .projects ? .project(id) : .learning(id))
  }
  for owner in owners {
    let attachment = try await db.importAttachment(data: entryPNG, name: "相册.png", owner: owner)
    let fresh = try WorkspaceDatabase(url: url)
    let item = try #require(try await fresh.snapshot().item(.attachments, attachment.id))
    #expect(item.fields[owner.field] == .string(owner.id))
    #expect(
      try Data(contentsOf: f.directory.appendingPathComponent("attachments/" + attachment.fileKey))
        == entryPNG)
    #expect(
      try await fresh.pendingDocuments().contains {
        $0.entity == "attachments" && $0.id == attachment.id
      })
  }
}
