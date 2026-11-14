import CloudKit
import Foundation
import Security

// Existing CloudKit wire protocol; native Swift stores own merge rules and journaling.
func archive(_ record: CKRecord) throws -> String {
  let encoder = NSKeyedArchiver(requiringSecureCoding: true)
  record.encodeSystemFields(with: encoder)
  encoder.finishEncoding()
  return encoder.encodedData.base64EncodedString()
}
private func document(_ record: CKRecord, assetDirectory: URL) throws -> [String: Any] {
  guard let entity = record["entity"] as? String, let id = record["localID"] as? String,
    record.recordID.recordName == "\(entity):\(id)"
  else {
    throw NSError(
      domain: "Workbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud 数据格式不正确"])
  }
  var payload: Any = NSNull()
  if (record["deleted"] as? NSNumber)?.boolValue != true {
    guard let raw = record["payload"] as? String else {
      throw NSError(
        domain: "Workbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud 记录缺少内容"])
    }
    payload = try JSONSerialization.jsonObject(with: Data(raw.utf8))
  }
  if entity == "attachments", let metadata = payload as? [String: Any] {
    guard let key = metadata["file_key"] as? String,
      key.range(
        of: "^[0-9a-fA-F-]{36}\\.(png|jpg|webp|gif|heic|avif|mp4|mov|webm)$",
        options: .regularExpression) != nil,
      let asset = record["media"] as? CKAsset, let source = asset.fileURL
    else { throw cloudError("iCloud 附件缺少文件，请稍后重试") }
    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
    let target = assetDirectory.appendingPathComponent(key)
    let staging = assetDirectory.appendingPathComponent(".download-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.copyItem(at: source, to: staging)
    // Replace atomically: no partially downloaded file is ever exposed to the UI.
    if FileManager.default.fileExists(atPath: target.path) {
      _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
    } else {
      try FileManager.default.moveItem(at: staging, to: target)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }
  return ["entity": entity, "id": id, "payload": payload, "serverFields": try archive(record)]
}
func cloudError(_ message: String) -> Error {
  NSError(domain: "Workbench", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
@MainActor func ensureRecordZone(fetch: () async throws -> Void, create: () async throws -> Void)
  async throws
{
  do { try await fetch() } catch let error as CKError
    where error.code == .zoneNotFound || error.code == .unknownItem
  {
    try await create()
  }
}
func describeCloudError(_ error: Error) -> String {
  if let message = cloudRecoveryMessage(error) { return message }
  let error = error as NSError
  var parts = [error.localizedDescription]
  for key in [
    NSLocalizedFailureReasonErrorKey, NSDebugDescriptionErrorKey, "ServerDescription",
    "CKErrorDescription",
  ] {
    if let detail = error.userInfo[key] as? String, !parts.contains(detail) { parts.append(detail) }
  }
  if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
    let detail = describeCloudError(underlying)
    if !parts.contains(detail) { parts.append(detail) }
  }
  return parts.joined(separator: " · ")
}
@MainActor func nativeCloudExchange(_ input: [String: Any]) async throws -> [String: Any] {
  if ProcessInfo.processInfo.environment["WORKBENCH_QA"] == "1" { return ["enabled": false] }
  let enabled = Bundle.main.object(forInfoDictionaryKey: "WorkbenchCloudEnabled")
  guard enabled as? String == "YES" || enabled as? Bool == true else { return ["enabled": false] }
  guard
    let containerID = Bundle.main.object(forInfoDictionaryKey: "WorkbenchCloudContainer") as? String
  else { throw cloudError("尚未配置 iCloud 容器") }
  #if os(macOS)
    // Ad-hoc/local preview builds must never instantiate CloudKit without a valid entitlement.
    guard let task = SecTaskCreateFromSelf(nil),
      let services = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
      services.contains("CloudKit"),
      let containers = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
      containers.contains(containerID),
      let environment = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.icloud-container-environment" as CFString, nil) as? String
    else {
      throw cloudError("Mac 尚未配置 iCloud 签名，请使用开发者证书和描述文件构建")
    }
  #else
    guard
      let environment = Bundle.main.object(forInfoDictionaryKey: "WorkbenchCloudEnvironment")
        as? String
    else { throw cloudError("尚未配置 iCloud 环境") }
  #endif
  let container = CKContainer(identifier: containerID)
  let database = container.privateCloudDatabase
  guard try await container.accountStatus() == .available else {
    throw cloudError("请在系统设置登录 iCloud")
  }
  let account = try await container.userRecordID().recordName
  if input["operation"] as? String == "identity" {
    return [
      "enabled": true, "container": containerID, "account": account, "environment": environment,
    ]
  }
  guard input["account"] as? String == account else { throw cloudError("iCloud 账号已改变，同步暂停") }
  if (input["operation"] as? String)?.hasPrefix("photo.") == true {
    return try await photoCloudExchange(
      input, container: container, account: account, environment: environment)
  }
  let zone = CKRecordZone.ID(zoneName: "Workbench", ownerName: CKCurrentUserDefaultName)
  do {
    try await ensureRecordZone(
      fetch: {
        let results = try await database.recordZones(for: [zone])
        guard let result = results[zone] else { throw cloudError("iCloud 未返回区域信息") }
        _ = try result.get()
      },
      create: {
        _ = try await database.save(CKRecordZone(zoneID: zone))
      })
  } catch { throw contextualCloudError("初始化 iCloud", error) }
  guard let assetPath = input["assetDirectory"] as? String else { throw cloudError("附件目录不可用") }
  let assetDirectory = URL(fileURLWithPath: assetPath, isDirectory: true)
  if input["operation"] as? String == "pull" {
    var token: CKServerChangeToken?
    if let raw = input["token"] as? String, !raw.isEmpty, let data = Data(base64Encoded: raw) {
      token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
    do {
      let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token)
      var documents = try changes.modificationResultsByID.values.map {
        try document($0.get().record, assetDirectory: assetDirectory)
      }
      for deletion in changes.deletions {
        let pieces = deletion.recordID.recordName.split(separator: ":", maxSplits: 1).map(
          String.init)
        if pieces.count == 2 {
          documents.append(["entity": pieces[0], "id": pieces[1], "payload": NSNull()])
        }
      }
      let encoded = try NSKeyedArchiver.archivedData(
        withRootObject: changes.changeToken, requiringSecureCoding: true
      ).base64EncodedString()
      return [
        "enabled": true, "documents": documents, "token": encoded, "more": changes.moreComing,
      ]
    } catch let error as CKError where error.code == .changeTokenExpired {
      return ["expired": true]
    } catch { throw contextualCloudError("读取 iCloud", error) }
  }
  var acknowledgements: [[String: Any]] = []
  var conflicts: [[String: Any]] = []
  let documents = input["documents"] as? [[String: Any]] ?? []
  for offset in stride(from: 0, to: documents.count, by: 100) {
    let batch = Array(documents[offset..<min(offset + 100, documents.count)])
    var records: [CKRecord] = []
    for pending in batch {
      guard let entity = pending["entity"] as? String, let id = pending["id"] as? String else {
        throw cloudError("同步格式不正确")
      }
      let recordID = CKRecord.ID(recordName: "\(entity):\(id)", zoneID: zone)
      let record: CKRecord
      if let raw = pending["serverFields"] as? String, let data = Data(base64Encoded: raw) {
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = true
        record =
          CKRecord(coder: decoder) ?? CKRecord(recordType: "WorkbenchRecord", recordID: recordID)
        decoder.finishDecoding()
      } else {
        record = CKRecord(recordType: "WorkbenchRecord", recordID: recordID)
      }
      record["entity"] = entity as CKRecordValue
      record["localID"] = id as CKRecordValue
      let payload = pending["payload"]
      let deleted = payload == nil || payload is NSNull
      record["deleted"] = NSNumber(value: deleted)
      if deleted {
        record["payload"] = nil
      } else {
        record["payload"] =
          String(data: try JSONSerialization.data(withJSONObject: payload!), encoding: .utf8)!
          as CKRecordValue
      }
      if entity == "attachments" {
        if deleted {
          record["media"] = nil
        } else {
          guard let metadata = payload as? [String: Any], let key = metadata["file_key"] as? String,
            key.range(
              of: "^[0-9a-fA-F-]{36}\\.(png|jpg|webp|gif|heic|avif|mp4|mov|webm)$",
              options: .regularExpression) != nil
          else { throw cloudError("附件名称不正确") }
          let url = assetDirectory.appendingPathComponent(key)
          guard FileManager.default.fileExists(atPath: url.path) else {
            throw cloudError("附件尚未下载，请同步后重试")
          }
          record["media"] = CKAsset(fileURL: url)
        }
      }
      records.append(record)
    }
    do {
      let saved = try await database.modifyRecords(
        saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
      var failure: String?
      for (record, pending) in zip(records, batch) {
        do {
          guard let result = saved.saveResults[record.recordID] else {
            throw cloudError("iCloud 未返回保存结果")
          }
          acknowledgements.append(["pending": pending, "serverFields": try archive(result.get())])
        } catch let error as CKError where error.code == .serverRecordChanged {
          if let server = error.serverRecord {
            conflicts.append(
              try document(
                try await database.record(for: server.recordID), assetDirectory: assetDirectory))
          } else {
            failure = describeCloudError(error)
          }
        } catch { failure = describeCloudError(error) }
      }
      if let failure {
        return ["acks": acknowledgements, "conflicts": conflicts, "error": failure]
      }
    } catch {
      // Return acknowledgements from earlier batches even if this batch failed.
      return [
        "acks": acknowledgements, "conflicts": conflicts,
        "error": "上传 iCloud：" + describeCloudError(error),
      ]
    }
  }
  return ["acks": acknowledgements, "conflicts": conflicts]
}
// Called on the document service actor, never on the UI thread.
func writeImmutableBackup(_ data: Data, folder: URL, name: String) throws -> URL {
  guard name.hasSuffix(".json"), !name.hasPrefix("."),
    name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
    let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    document["version"] as? Int == 1, document["state"] is [String: Any]
  else { throw cloudError("备份格式不正确") }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let url = folder.appendingPathComponent(name)
  var coordinationError: NSError?
  var failure: Error?
  NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) {
    target in
    do {
      if FileManager.default.fileExists(atPath: target.path) {
        guard try Data(contentsOf: target) == data else { throw cloudError("同名历史备份已存在，不会覆盖") }
      } else {
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
    } catch { failure = error }
  }
  if let error = coordinationError ?? failure as NSError? { throw error }
  return url
}
func nativeDriveExchange(_ input: [String: Any]) throws -> [String: Any] {
  guard !Thread.isMainThread else { throw cloudError("云盘备份需要在后台执行") }
  guard ProcessInfo.processInfo.environment["WORKBENCH_QA"] != "1" else {
    throw cloudError("测试模式不写入 iCloud 云盘")
  }
  guard
    let identifier = Bundle.main.object(forInfoDictionaryKey: "WorkbenchCloudContainer") as? String,
    let token = FileManager.default.ubiquityIdentityToken as? NSObject
  else { throw cloudError("请登录 iCloud 并开启 iCloud 云盘") }
  guard token is any NSSecureCoding else { throw cloudError("无法安全验证 iCloud 账号，云盘备份暂停") }
  if let raw = input["identity"] as? String, !raw.isEmpty {
    guard let data = Data(base64Encoded: raw),
      let previous = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSObject.self], from: data)
        as? NSObject,
      token.isEqual(previous)
    else { throw cloudError("iCloud 账号已改变，云盘备份暂停") }
  }
  guard let container = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
    throw cloudError("iCloud 云盘不可用，请检查应用的 iCloud Documents 权限")
  }
  let folder = container.appendingPathComponent("Documents/Backups", isDirectory: true)
  let identity = try NSKeyedArchiver.archivedData(
    withRootObject: token, requiringSecureCoding: true
  ).base64EncodedString()
  if input["operation"] as? String == "prepare" {
    return ["identity": identity, "folder": folder.path]
  }
  guard let name = input["name"] as? String else { throw cloudError("备份名称不正确") }
  let url: URL
  if input["operation"] as? String == "write" {
    guard let raw = input["document"] as? String else { throw cloudError("缺少备份内容") }
    let mediaFolder = folder.appendingPathComponent("attachments", isDirectory: true)
    for asset in input["assets"] as? [[String: Any]] ?? [] {
      guard let key = asset["key"] as? String, let path = asset["path"] as? String,
        key.range(
          of: "^[0-9a-fA-F-]{36}\\.(png|jpg|webp|gif|heic|avif|mp4|mov|webm)$",
          options: .regularExpression) != nil
      else { throw cloudError("备份附件格式不正确") }
      try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
      let destination = mediaFolder.appendingPathComponent(key)
      var coordinationError: NSError?
      var failure: Error?
      NSFileCoordinator().coordinate(
        writingItemAt: destination, options: [], error: &coordinationError
      ) { target in
        do {
          if !FileManager.default.fileExists(atPath: target.path) {
            let temporary = mediaFolder.appendingPathComponent(".copy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: temporary)
            try FileManager.default.moveItem(at: temporary, to: target)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: target.path)
          }
        } catch { failure = error }
      }
      if let error = coordinationError ?? failure as NSError? { throw error }
    }
    url = try writeImmutableBackup(Data(raw.utf8), folder: folder, name: name)
  } else {
    guard name.hasSuffix(".json"), !name.hasPrefix("."),
      name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    else { throw cloudError("备份名称不正确") }
    url = folder.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw cloudError("最近一次云盘备份文件已不在本机，本地副本仍保留")
    }
  }
  let values = try url.resourceValues(forKeys: [
    .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey,
  ])
  if let error = values.ubiquitousItemUploadingError { throw error }
  return [
    "identity": identity, "folder": folder.path, "path": url.path,
    "uploaded": values.ubiquitousItemIsUploaded == true,
  ]
}
