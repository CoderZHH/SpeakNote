import Foundation
import SwiftUI

/// The timer is a projection of the persisted session, never a second stopwatch.
public struct FocusTimerState: Codable, Hashable, Sendable {
  public var title: String
  public var accumulatedSeconds: Int64
  public var activeSince: Date?
  public var isRunning: Bool
  public init(title: String, accumulatedSeconds: Int64, activeSince: Date?, isRunning: Bool) {
    self.title = title
    self.accumulatedSeconds = max(0, accumulatedSeconds)
    self.activeSince = activeSince
    self.isRunning = isRunning
  }
  public var timerStart: Date? {
    guard isRunning, let activeSince else { return nil }
    return activeSince.addingTimeInterval(-Double(accumulatedSeconds))
  }
  public func elapsed(at now: Date) -> Int64 {
    let extra = isRunning ? max(0, now.timeIntervalSince(activeSince ?? now)) : 0
    let base = max(0, accumulatedSeconds)
    guard extra < Double(Int64.max - base) else { return Int64.max }
    return base + Int64(extra)
  }
  public func elapsedText(at now: Date) -> String {
    let value = elapsed(at: now)
    return String(format: "%02lld:%02lld:%02lld", value / 3600, value / 60 % 60, value % 60)
  }
}

public struct FocusTimerText: View {
  public let state: FocusTimerState
  public init(state: FocusTimerState) { self.state = state }
  public var body: some View {
    let anchor = Date()
    let start =
      state.timerStart ?? anchor.addingTimeInterval(-Double(max(0, state.accumulatedSeconds)))
    Text(
      timerInterval: start...Date.distantFuture,
      pauseTime: state.timerStart == nil ? anchor : nil, countsDown: false, showsHours: true
    )
    .monospacedDigit()
  }
}
