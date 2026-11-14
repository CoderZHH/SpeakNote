import Foundation

/// JSONSerialization dictionaries stay on this actor; only Sendable values cross boundaries.
@MainActor public final class CloudService {
  public init() {}
  public func exchange(_ request: JSONValue) async throws -> JSONValue {
    let input = try JSONSerialization.jsonObject(with: request.data()) as? [String: Any] ?? [:]
    do {
      let result: [String: Any]
      if ["identity", "pull", "photo.pull", "photo.discover"].contains(input["operation"] as? String ?? "") {
        result = try await withCloudReadRetry { try await nativeCloudExchange(input) }
      } else {
        result = try await nativeCloudExchange(input)
      }
      return try JSONValue(data: JSONSerialization.data(withJSONObject: result))
    } catch is CancellationError { throw CancellationError() }
    catch { throw contextualCloudError("iCloud 同步未完成", error) }
  }

}
public actor CloudDocumentsService {
  public init() {}
  public func exchange(_ request: JSONValue) throws -> JSONValue {
    let input = try JSONSerialization.jsonObject(with: request.data()) as? [String: Any] ?? [:]
    return try JSONValue(data: JSONSerialization.data(withJSONObject: nativeDriveExchange(input)))
  }
}
