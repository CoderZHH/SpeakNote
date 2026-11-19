import Foundation
import SwiftUI

/// The timer is a projection of the persisted session, never a second stopwatch.
public struct FocusTimerState: Codable, Hashable, Sendable {
  public var title: String
  public var accumulatedSeconds: Int64
  public var activeSince: Date?
  public var isRunning: Bool
  public var goalSeconds: Int64

  public init(
    title: String,
    accumulatedSeconds: Int64,
    activeSince: Date?,
    isRunning: Bool,
    goalSeconds: Int64 = 0
  ) {
    self.title = title
    self.accumulatedSeconds = max(0, accumulatedSeconds)
    self.activeSince = activeSince
    self.isRunning = isRunning
    self.goalSeconds = max(0, goalSeconds)
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

  public func remaining(at now: Date) -> Int64? {
    guard goalSeconds > 0 else { return nil }
    return goalSeconds - elapsed(at: now)
  }

  public func progress(at now: Date) -> Double? {
    guard goalSeconds > 0 else { return nil }
    return min(1.0, max(0.0, Double(elapsed(at: now)) / Double(goalSeconds)))
  }

  public func elapsedText(at now: Date) -> String {
    let value = elapsed(at: now)
    return Self.format(seconds: value)
  }

  public static func format(seconds: Int64) -> String {
    let v = max(0, seconds)
    return String(format: "%02lld:%02lld:%02lld", v / 3600, v / 60 % 60, v % 60)
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
