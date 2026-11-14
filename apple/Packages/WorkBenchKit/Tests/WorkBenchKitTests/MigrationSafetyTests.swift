import Foundation
import Testing

@testable import WorkBenchKit

@Test func firstLaunchBacksUpBothDatabasesAndExistingPhotoAttachments() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let workspace = try fixture.workspace()
  _ = try workspace.perform(
    .create(.tasks, id: "kept-task", fields: [.title: .string("保留原任务")]), now: testNow)
  let photos = try fixture.photos()
  try photos.bind(fixture.space)
  var order = PhotoOrderInput()
  order.brand = "保留原订单"
  _ = try photos.perform(.create(order), now: testNow)
  let personalAssets = fixture.directory.appendingPathComponent("attachments", isDirectory: true)
  try FileManager.default.createDirectory(at: personalAssets, withIntermediateDirectories: true)
  let personalData = Data("personal-attachment".utf8)
  let photoData = Data("photo-attachment".utf8)
  try personalData.write(to: personalAssets.appendingPathComponent("kept.jpg"))
  try photoData.write(to: photos.assets.appendingPathComponent("kept.png"))
  let originalTask = try workspace.db.record("tasks", id: "kept-task")
  let originalPhotoRecords = try photos.db.rows("SELECT * FROM photo_records ORDER BY id")
  var lease: WriterLease? = try MigrationSafety.prepare(
    .init(directory: fixture.directory, role: .workbench))
  let markerURL = fixture.directory.appendingPathComponent("native-migration-v1.json")
  let manifest = try JSONValue(data: Data(contentsOf: markerURL))
  let backup = URL(fileURLWithPath: manifest["backup"].string, isDirectory: true)
  #expect(manifest["databases"].array.count == 2)
  #expect(manifest["media"].array.count == 2)
  #expect(
    try Data(contentsOf: backup.appendingPathComponent("attachments/kept.jpg")) == personalData)
  #expect(
    try Data(contentsOf: backup.appendingPathComponent("photo-attachments/kept.png")) == photoData)
  #expect(
    try SQLite(backup.appendingPathComponent("workbench.sqlite"), readOnly: true).record(
      "tasks", id: "kept-task") == originalTask)
  #expect(
    try SQLite(backup.appendingPathComponent("photo.sqlite"), readOnly: true).rows(
      "SELECT * FROM photo_records ORDER BY id") == originalPhotoRecords)
  #expect(
    !FileManager.default.fileExists(atPath: backup.appendingPathComponent(".validation").path))
  #expect(try workspace.db.record("tasks", id: "kept-task") == originalTask)
  #expect(try Data(contentsOf: photos.assets.appendingPathComponent("kept.png")) == photoData)
  withExtendedLifetime(lease) {}
  lease = nil
  let markerData = try Data(contentsOf: markerURL)
  let secondLease = try MigrationSafety.prepare(
    .init(directory: fixture.directory, role: .workbench))
  #expect(try Data(contentsOf: markerURL) == markerData)
  #expect(
    try FileManager.default.contentsOfDirectory(
      at: fixture.directory.appendingPathComponent("native-migration-backups"),
      includingPropertiesForKeys: nil
    ).count == 1)
  withExtendedLifetime(secondLease) {}
}

@Test func assistantMigrationNeverOpensOrCopiesPersonalDatabase() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let privateContents = Data("not-a-database-private-contents".utf8)
  try privateContents.write(to: fixture.directory.appendingPathComponent("workbench.sqlite"))
  let photos = try fixture.photos()
  try Data("photo".utf8).write(to: photos.assets.appendingPathComponent("kept.png"))
  let lease = try MigrationSafety.prepare(
    .init(directory: fixture.directory, role: .photoAssistant))
  let manifest = try JSONValue(
    data: Data(contentsOf: fixture.directory.appendingPathComponent("native-migration-v1.json")))
  let backup = URL(fileURLWithPath: manifest["backup"].string)
  #expect(manifest["databases"].array.map { $0["file"].string } == ["photo.sqlite"])
  #expect(
    !FileManager.default.fileExists(atPath: backup.appendingPathComponent("workbench.sqlite").path))
  #expect(
    try Data(contentsOf: fixture.directory.appendingPathComponent("workbench.sqlite"))
      == privateContents)
  withExtendedLifetime(lease) {}
}

@Test func closedWALDatabaseSupportsQueryOnlyBackup() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  var photos: PhotoEngine? = try fixture.photos()
  try photos!.bind(fixture.space)
  photos = nil
  let source = fixture.directory.appendingPathComponent("photo.sqlite")
  let destination = fixture.directory.appendingPathComponent("offline-backup.sqlite")
  try SQLite(source, backupSource: true).backup(to: destination)
  #expect(
    try SQLite(destination, readOnly: true).one("SELECT COUNT(*) AS n FROM photo_settings").integer(
      "n") > 0)
}

@Test(arguments: [1024, 4096, 16384])
func backupPreservesLegacyPageSize(pageSize: Int) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let source = fixture.directory.appendingPathComponent("legacy.sqlite")
  let destination = fixture.directory.appendingPathComponent("backup.sqlite")
  do {
    let database = try SQLite(source, useWAL: false)
    try database.script(
      "PRAGMA page_size=\(pageSize); CREATE TABLE kept(id TEXT PRIMARY KEY); INSERT INTO kept VALUES('original'); PRAGMA journal_mode=WAL;"
    )
  }
  let reader = try SQLite(source, backupSource: true)
  #expect(throws: (any Error).self) { try reader.execute("DELETE FROM kept") }
  try reader.backup(to: destination)
  let backup = try SQLite(destination, readOnly: true)
  #expect(try backup.one("PRAGMA page_size").integer("page_size") == pageSize)
  #expect(try backup.one("SELECT id FROM kept").text("id") == "original")
}
