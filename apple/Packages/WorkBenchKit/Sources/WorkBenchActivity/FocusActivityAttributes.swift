#if os(iOS)
  import ActivityKit

  public struct FocusActivityAttributes: ActivityAttributes {
    public typealias ContentState = FocusTimerState
    public let focusID: String
    public init(focusID: String) { self.focusID = focusID }
  }
#endif
