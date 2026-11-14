import CryptoKit
import Foundation
import WorkBenchKit

struct ConversationMessage: Codable, Sendable {
  let id: String
  let packet: JSONValue
}

struct ConversationBatch: Codable, Sendable {
  var messages: [ConversationMessage]
  let startedAt: Date
  var lastReceivedAt: Date

  static let quietInterval: TimeInterval = 2
  static let maximumInterval: TimeInterval = 10
  static let maximumMessages = 20

  init(_ message: ConversationMessage, now: Date) {
    messages = [message]
    startedAt = now
    lastReceivedAt = now
  }

  mutating func append(_ message: ConversationMessage, now: Date) {
    guard !messages.contains(where: { $0.id == message.id }) else { return }
    messages.append(message)
    lastReceivedAt = now
  }

  func waitInterval(now: Date) -> TimeInterval {
    guard messages.count < Self.maximumMessages else { return 0 }
    return max(0, min(lastReceivedAt.addingTimeInterval(Self.quietInterval).timeIntervalSince(now),
      startedAt.addingTimeInterval(Self.maximumInterval).timeIntervalSince(now)))
  }

  var items: [JSONValue] { messages.flatMap { $0.packet["item_list"].array } }
  var latestPacket: JSONValue { messages.last?.packet ?? .null }

  func requestID(bot: String) -> String {
    let source = [bot] + messages.map(\.id)
    return "wechat-" + SHA256.hash(data: Data(source.joined(separator: "|").utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}
