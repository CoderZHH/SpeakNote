import CloudKit
import Foundation

// Inspect the original errors before formatting them; CloudKit wraps URL/TLS failures.
private func cloudErrorChain(_ error: Error) -> [NSError] {
  var result: [NSError] = []
  var current: NSError? = error as NSError
  var visited = Set<ObjectIdentifier>()
  while let error = current, result.count < 16,
    visited.insert(ObjectIdentifier(error)).inserted
  {
    result.append(error)
    current = error.userInfo[NSUnderlyingErrorKey] as? NSError
  }
  return result
}

func cloudRecoveryMessage(_ error: Error) -> String? {
  let chain = cloudErrorChain(error)
  if chain.contains(where: { $0.domain == NSURLErrorDomain && (-1206 ... -1201).contains($0.code) }) {
    return "无法验证 iCloud 的安全证书。请检查系统日期及网络代理的证书设置后重试。"
  }
  if chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorSecureConnectionFailed }) {
    return "与 iCloud 的安全连接未能建立（-1200）。请稍后重试；若持续出现，请尝试切换网络或检查 VPN、代理设置。本机内容仍保留。"
  }
  if chain.contains(where: { $0.domain == CKErrorDomain && $0.code == CKError.notAuthenticated.rawValue }) {
    return "请在系统设置中检查 iCloud 登录状态后重试。本机内容仍保留。"
  }
  if cloudRetryDelay(error, attempt: 0) != nil {
    return "暂时无法连接 iCloud，请检查网络后重试。本机内容仍保留。"
  }
  return nil
}

func contextualCloudError(_ context: String, _ error: Error) -> Error {
  NSError(domain: "Workbench.Cloud", code: 1, userInfo: [
    NSLocalizedDescriptionKey: context + "：" + describeCloudError(error),
    NSUnderlyingErrorKey: error,
  ])
}

func cloudRetryDelay(_ error: Error, attempt: Int) -> TimeInterval? {
  let chain = cloudErrorChain(error)
  // A CloudKit network error must not turn a certificate failure into a retry loop.
  if chain.contains(where: { $0.domain == NSURLErrorDomain && (-1206 ... -1201).contains($0.code) }) {
    return nil
  }
  let urlCodes = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
    NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorSecureConnectionFailed]
  let cloudCodes: [CKError.Code] = [.networkFailure, .networkUnavailable, .serviceUnavailable,
    .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable]
  guard chain.contains(where: {
    ($0.domain == NSURLErrorDomain && urlCodes.contains($0.code))
      || ($0.domain == CKErrorDomain && cloudCodes.map(\.rawValue).contains($0.code))
  }) else { return nil }
  let backoff = attempt == 0 ? 1.0 : 3.0
  let serverDelay = chain.compactMap { ($0.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue }
    .filter { $0.isFinite && $0 >= 0 }.max() ?? 0
  return max(backoff, serverDelay)
}

// Only reads are replayed. Uploads must return partial acknowledgements to the store first.
@MainActor func withCloudReadRetry<Value>(
  operation: () async throws -> Value,
  sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
) async throws -> Value {
  var attempt = 0
  while true {
    try Task.checkCancellation()
    do { return try await operation() }
    catch {
      guard attempt < 2, let delay = cloudRetryDelay(error, attempt: attempt), delay <= 30 else {
        throw error
      }
      attempt += 1
      try await sleep(delay)
    }
  }
}

@MainActor func syncIndependentScopes(
  workspace: () async throws -> Void, photos: () async throws -> Void
) async throws {
  var failures: [String] = []
  do { try await workspace() }
  catch is CancellationError { throw CancellationError() }
  catch { failures.append("个人工作区：" + describeCloudError(error)) }
  try Task.checkCancellation()
  do { try await photos() }
  catch is CancellationError { throw CancellationError() }
  catch { failures.append("拍照共享：" + describeCloudError(error)) }
  if !failures.isEmpty { throw WorkBenchError(failures.joined(separator: "\n")) }
}
