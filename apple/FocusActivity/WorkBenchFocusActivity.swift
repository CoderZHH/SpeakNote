import ActivityKit
import SwiftUI
import WidgetKit
import WorkBenchActivity

@main struct WorkBenchFocusWidgets: WidgetBundle {
  var body: some Widget { WorkBenchFocusActivity() }
}

struct WorkBenchFocusActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FocusActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: context.state.isRunning ? "timer" : "pause.circle")
          .font(.title2).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text(context.state.title).font(.headline).lineLimit(2)
          Text(context.state.isRunning ? "专注中" : "已暂停").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        FocusTimerText(state: context.state).font(.title2.weight(.medium)).fixedSize()
      }.padding(16).activityBackgroundTint(.black.opacity(0.85))
        .activitySystemActionForegroundColor(.white)
        .foregroundStyle(.white).widgetURL(URL(string: "workbench-preview://focus"))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(
            context.state.isRunning ? "专注中" : "已暂停",
            systemImage: context.state.isRunning ? "timer" : "pause.circle"
          ).font(.caption)
        }
        DynamicIslandExpandedRegion(.trailing) {
          FocusTimerText(state: context.state).font(.title3.weight(.medium))
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.title).font(.headline).lineLimit(2).frame(
            maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: context.state.isRunning ? "timer" : "pause.fill").foregroundStyle(.cyan)
      } compactTrailing: {
        FocusTimerText(state: context.state).font(.caption2).frame(width: 62)
      } minimal: {
        Image(systemName: context.state.isRunning ? "timer" : "pause.fill").foregroundStyle(.cyan)
      }.widgetURL(URL(string: "workbench-preview://focus")).keylineTint(.cyan)
    }
  }
}
