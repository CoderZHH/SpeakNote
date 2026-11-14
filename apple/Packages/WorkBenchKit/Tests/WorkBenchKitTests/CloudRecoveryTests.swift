import CloudKit
import XCTest

@testable import WorkBenchKit

final class CloudRecoveryTests: XCTestCase {
  private func tlsError(_ code: Int = NSURLErrorSecureConnectionFailed) -> NSError {
    NSError(domain: CKErrorDomain, code: CKError.networkFailure.rawValue, userInfo: [
      NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: code),
    ])
  }

  @MainActor func testWrappedTLSFailureRetriesThenSucceeds() async throws {
    var calls = 0
    var delays: [TimeInterval] = []
    let result = try await withCloudReadRetry(operation: {
      calls += 1
      if calls < 3 { throw contextualCloudError("初始化 iCloud", self.tlsError()) }
      return "downloaded"
    }, sleep: { delays.append($0) })
    XCTAssertEqual(result, "downloaded")
    XCTAssertEqual(calls, 3)
    XCTAssertEqual(delays, [1, 3])
  }

  @MainActor func testRetriesAreBoundedAndOriginalErrorSurvives() async {
    var calls = 0
    do {
      let _: Void = try await withCloudReadRetry(operation: {
        calls += 1
        throw self.tlsError()
      }, sleep: { _ in })
      XCTFail("A persistent failure must remain visible")
    } catch {
      XCTAssertEqual((error as NSError).domain, CKErrorDomain)
      XCTAssertTrue(describeCloudError(error).contains("-1200"))
      XCTAssertTrue(describeCloudError(error).contains("本机内容仍保留"))
    }
    XCTAssertEqual(calls, 3)
  }

  @MainActor func testCertificateAndAuthenticationErrorsAreNotRetried() async {
    for error in [tlsError(NSURLErrorServerCertificateUntrusted),
      NSError(domain: CKErrorDomain, code: CKError.notAuthenticated.rawValue)]
    {
      var calls = 0
      do {
        let _: Void = try await withCloudReadRetry(operation: {
          calls += 1
          throw error
        }, sleep: { _ in XCTFail("A user action is required") })
        XCTFail("Expected failure")
      } catch {}
      XCTAssertEqual(calls, 1)
    }
    XCTAssertTrue(describeCloudError(tlsError(NSURLErrorServerCertificateUntrusted)).contains("证书"))
  }

  @MainActor func testServerRetryAfterIsRespected() async throws {
    var calls = 0
    var delays: [TimeInterval] = []
    try await withCloudReadRetry(operation: {
      calls += 1
      if calls == 1 {
        throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0])
      }
    }, sleep: { delays.append($0) })
    XCTAssertEqual(delays, [7])
    do {
      let _: Void = try await withCloudReadRetry(operation: {
        throw CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 120.0])
      }, sleep: { _ in XCTFail("Long server delays must return control to the user") })
      XCTFail("Expected failure")
    } catch {}
  }

  @MainActor func testCancellationDuringBackoffDoesNotIssueAnotherRequest() async {
    var calls = 0
    do {
      let _: Void = try await withCloudReadRetry(operation: {
        calls += 1
        throw self.tlsError()
      }, sleep: { _ in throw CancellationError() })
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(calls, 1)
  }

  @MainActor func testWorkspaceFailureStillSyncsPhotosAndReportsBothFailures() async {
    var photoCalls = 0
    for photoFails in [false, true] {
      do {
        try await syncIndependentScopes(workspace: {
          throw self.tlsError()
        }, photos: {
          photoCalls += 1
          if photoFails { throw WorkBenchError("共享空间暂不可用") }
        })
        XCTFail("A failed scope must not report success")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("个人工作区"))
        XCTAssertEqual(error.localizedDescription.contains("拍照共享"), photoFails)
      }
    }
    XCTAssertEqual(photoCalls, 2)
  }
}
