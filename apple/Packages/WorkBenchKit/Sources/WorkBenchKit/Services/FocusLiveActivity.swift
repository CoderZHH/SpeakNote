#if os(iOS)
  // ActivityKit activities have not adopted Sendable in the SDK; this coordinator
  // owns all access and serializes every update on the main actor.
  @preconcurrency import ActivityKit
  import Observation
  import UIKit
  import WorkBenchActivity

  /// Coalesces snapshot refreshes. System date-based Text keeps running while the
  /// app is suspended; no per-second writes, background loop, or APNs is needed.
  @MainActor @Observable final class FocusLiveActivity {
    private(set) var notice: String?
    @ObservationIgnored private var desired: FocusPresentation?
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var sent: [String: FocusTimerState] = [:]
    @ObservationIgnored private var watches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissedFocusIDs: Set<String> = []

    func reconcile(_ focus: FocusPresentation?) async {
      desired = focus
      version += 1
      guard !reconciling else { return }
      reconciling = true
      defer { reconciling = false }
      while true {
        let current = version
        await apply(desired)
        if current == version { break }
      }
    }
    private func apply(_ focus: FocusPresentation?) async {
      let live = Activity<FocusActivityAttributes>.activities.filter {
        $0.activityState == .active || $0.activityState == .stale
      }
      let matching = live.filter { $0.attributes.focusID == focus?.id }
      let keepID = matching.first?.id
      // Remove a previous task or duplicate before showing a new session.
      for activity in live where activity.id != keepID {
        watches[activity.id]?.cancel()
        watches[activity.id] = nil
        await activity.end(nil, dismissalPolicy: .immediate)
        sent[activity.id] = nil
      }
      guard let focus else {
        dismissedFocusIDs = []
        notice = nil
        return
      }
      guard !dismissedFocusIDs.contains(focus.id) else {
        notice = nil
        return
      }
      var state = focus.timer
      // The system payload is small; long task descriptions stay in the app.
      state.title = String(state.title.prefix(160))
      let content = ActivityContent(state: state, staleDate: nil)
      if let activity = matching.first {
        watch(activity)
        if sent[activity.id] != state {
          await activity.update(content)
          sent[activity.id] = state
        }
        notice = nil
        return
      }
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        notice = "实时活动未开启，可在系统设置中允许。"
        return
      }
      // Only the foreground may start a new activity. An existing one can still
      // be updated in the background; returning to the app reconciles again.
      guard UIApplication.shared.applicationState == .active else { return }
      do {
        let activity = try Activity.request(
          attributes: FocusActivityAttributes(focusID: focus.id),
          content: content, pushType: nil)
        sent[activity.id] = state
        watch(activity)
        notice = nil
      } catch {
        notice = "暂时无法显示实时活动：" + error.localizedDescription
      }
    }
    private func watch(_ activity: Activity<FocusActivityAttributes>) {
      guard watches[activity.id] == nil else { return }
      watches[activity.id] = Task { [weak self] in
        for await state in activity.activityStateUpdates {
          guard !Task.isCancelled else { return }
          if state == .dismissed {
            // Respect a manual dismissal for this session, including later syncs.
            self?.dismissedFocusIDs.insert(activity.attributes.focusID)
          }
          if state == .dismissed || state == .ended {
            self?.sent[activity.id] = nil
            self?.watches[activity.id] = nil
            return
          }
        }
      }
    }
  }
#endif
