#if os(macOS)
  import AppKit
  import SwiftUI
  import WorkBenchActivity

  /// Behind-window AppKit frosted vibrancy clipped to a continuous squircle.
  private struct MenuBarBackdropBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
      let view = NSVisualEffectView()
      view.material = .popover
      view.blendingMode = .behindWindow
      view.state = .active
      view.isEmphasized = true
      view.wantsLayer = true
      view.layer?.cornerRadius = cornerRadius
      view.layer?.cornerCurve = .continuous
      view.layer?.masksToBounds = true
      return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
      nsView.state = .active
      nsView.layer?.cornerRadius = cornerRadius
    }
  }

  enum QuickCaptureKind: String, CaseIterable, Identifiable {
    case task = "待办"
    case note = "随手记"
    var id: String { rawValue }
  }

  struct MenuBarQuickPanelView: View {
    let session: AppSession
    let openWorkspace: (AppModule?) -> Void
    let openGlobalSearch: () -> Void
    let closePanel: () -> Void
    var onHeightChange: ((CGFloat) -> Void)? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("preferredFocusGoalSeconds") private var preferredGoalSeconds = 0
    @State private var captureKind: QuickCaptureKind = .task
    @State private var draft = ""
    @State private var plannedToday = true
    @State private var saving = false
    @State private var savedCheck = false
    @State private var hoveredTaskID: String?
    @State private var hoveringMode = false
    @State private var hoveringFocusIcon = false
    @State private var hoveringOpenIcon = false
    @FocusState private var inputFocused: Bool

    private let panelRadius: CGFloat = 18

    private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
    private var todayString: String { Clock.day() }

    private var todayPendingTasks: [WorkspaceItem] {
      snapshot[.tasks]
        .filter { isTaskDueForToday($0, day: todayString) }
        .sorted(by: taskImportanceOrder)
    }

    private var canSubmitCapture: Bool {
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        captureBar

        if let focus = session.focusStatus {
          activeFocusBar(focus)
        }

        if !todayPendingTasks.isEmpty {
          Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055))
            .frame(height: 0.5)
            .padding(.horizontal, 2)

          VStack(spacing: 1) {
            ForEach(todayPendingTasks.prefix(5)) { task in
              menuTaskRow(task)
            }
          }
        }
      }
      .padding(12)
      .frame(width: 332)
      .background { glassBackdrop }
      .clipShape(.rect(cornerRadius: panelRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
          .strokeBorder(
            Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08),
            lineWidth: 0.5
          )
      }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { _, newHeight in
        onHeightChange?(newHeight)
      }
      .onAppear {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
          inputFocused = true
        }
      }
      .onExitCommand { closePanel() }
    }

    private var glassBackdrop: some View {
      ZStack {
        if reduceTransparency {
          WorkbenchDesign.canvas
        } else {
          MenuBarBackdropBlur(cornerRadius: panelRadius)
          Color.white.opacity(colorScheme == .dark ? 0.03 : 0.34)
        }
      }
    }

    // MARK: - 1. Minimalist Spotlight Capture Bar

    private var captureBar: some View {
      HStack(alignment: .center, spacing: 8) {
        Button {
          captureKind = captureKind == .task ? .note : .task
          inputFocused = true
        } label: {
          Text(captureKind.rawValue)
            .font(.system(size: 12, weight: .medium))
            .tracking(0.2)
            .foregroundStyle(captureKind == .task ? .primary : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              Color.primary.opacity(hoveringMode ? 0.09 : 0.055),
              in: .rect(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hoveringMode = $0 }
        .help("点击或按 Tab 切换「待办 / 随手记」")

        TextField(
          captureKind == .task ? "记一条待办…" : "随手记一笔…",
          text: $draft,
          axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(size: 14, weight: .regular))
        .lineLimit(1...4)
        .focused($inputFocused)
        .onKeyPress(.tab, phases: .down) { _ in
          captureKind = captureKind == .task ? .note : .task
          return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
          if press.modifiers.contains(.shift) { return .ignored }
          submitCapture()
          return .handled
        }
        .accessibilityIdentifier("menubar.capture.input")

        if savedCheck {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.green)
            .frame(width: 24, height: 24)
            .transition(.opacity)
        } else if canSubmitCapture {
          if captureKind == .task {
            Button {
              plannedToday.toggle()
            } label: {
              Text(plannedToday ? "今日" : "以后")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(plannedToday ? Color.accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  plannedToday ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.05),
                  in: .rect(cornerRadius: 6, style: .continuous)
                )
            }
            .buttonStyle(.plain)
          }

          Button(action: submitCapture) {
            Image(systemName: "return")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.accentColor)
              .frame(width: 24, height: 24)
              .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(saving)
          .accessibilityLabel("保存")
        } else {
          HStack(spacing: 2) {
            if session.focusStatus == nil {
              Menu {
                ForEach(FocusGoalPreset.allCases) { preset in
                  Button {
                    preferredGoalSeconds = preset.rawValue
                    let firstID = todayPendingTasks.first?.id
                    session.run {
                      _ = try await session.workspace?.perform(
                        .startFocus(taskID: firstID, goalSeconds: preset.rawValue))
                    }
                  } label: {
                    Text("开始专注 · \(preset.shortLabel)")
                  }
                }
              } label: {
                Image(systemName: "timer")
                  .font(.system(size: 12.5, weight: .regular))
                  .foregroundStyle(hoveringFocusIcon ? .primary : .secondary)
                  .frame(width: 24, height: 24)
                  .background(
                    hoveringFocusIcon ? Color.primary.opacity(0.07) : .clear,
                    in: .rect(cornerRadius: 6, style: .continuous)
                  )
              } primaryAction: {
                let firstID = todayPendingTasks.first?.id
                let goal = preferredGoalSeconds
                session.run {
                  _ = try await session.workspace?.perform(
                    .startFocus(taskID: firstID, goalSeconds: goal))
                }
              }
              .menuStyle(.borderlessButton)
              .menuIndicator(.hidden)
              .fixedSize()
              .onHover { hoveringFocusIcon = $0 }
              .help("点击开启专注（长按选择番茄时长）")
            }

            Button {
              closePanel()
              openWorkspace(nil)
            } label: {
              Image(systemName: "arrow.up.right")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hoveringOpenIcon ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                  hoveringOpenIcon ? Color.primary.opacity(0.07) : .clear,
                  in: .rect(cornerRadius: 6, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .onHover { hoveringOpenIcon = $0 }
            .help("打开随口记主窗口")
          }
        }
      }
      .padding(.leading, 7)
      .padding(.trailing, 6)
      .padding(.vertical, 6)
      .background(
        Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.04),
        in: .rect(cornerRadius: 11, style: .continuous)
      )
    }

    // MARK: - 2. Active Focus Bar (Only Visible While Focusing)

    private func activeFocusBar(_ focus: FocusPresentation) -> some View {
      let running = focus.timer.isRunning
      let tint: Color = running ? .accentColor : .orange
      return TimelineView(.periodic(from: .now, by: 1)) { context in
        let progress = focus.timer.progress(at: context.date)
        let goalReached = (focus.timer.remaining(at: context.date) ?? 1) <= 0 && focus.timer.goalSeconds > 0

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 7) {
            Circle()
              .fill(tint)
              .frame(width: 5.5, height: 5.5)

            Menu {
              Menu("目标时长") {
                ForEach(FocusGoalPreset.allCases) { preset in
                  Button {
                    preferredGoalSeconds = preset.rawValue
                    session.run {
                      _ = try await session.workspace?.perform(
                        .updateFocusGoal(id: focus.id, goalSeconds: preset.rawValue))
                    }
                  } label: {
                    if Int(focus.timer.goalSeconds) == preset.rawValue {
                      Label(preset.shortLabel, systemImage: "checkmark")
                    } else {
                      Text(preset.shortLabel)
                    }
                  }
                }
              }
              Divider()
              Button("放弃本次计时（不保存）", systemImage: "trash", role: .destructive) {
                session.run {
                  _ = try await session.workspace?.perform(.delete(.focusSessions, id: focus.id))
                }
              }
            } label: {
              HStack(spacing: 3) {
                Text(focus.timer.title)
                  .font(.system(size: 13, weight: .medium))
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                Image(systemName: "chevron.down")
                  .font(.system(size: 8, weight: .semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("调整目标时长或放弃本次计时")

            FocusTimerText(state: focus.timer)
              .font(.system(size: 14.5, weight: .medium, design: .rounded).monospacedDigit())
              .foregroundStyle(.primary)
          }

          HStack(spacing: 6) {
            if focus.timer.goalSeconds > 0 {
              let gLabel = FocusGoalPreset.label(for: focus.timer.goalSeconds)
              Text(goalReached ? "✓ 已达标 \(gLabel)" : "目标 \(gLabel)")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(goalReached ? .green : .secondary)
            }

            Spacer(minLength: 0)

            flatTextPill(
              title: running ? "暂停" : "继续",
              tint: .primary,
              helpText: running ? "暂停专注" : "继续专注"
            ) {
              session.run {
                _ = try await session.workspace?.perform(
                  running ? .pauseFocus : .startFocus(taskID: focus.taskID))
              }
            }

            flatTextPill(
              title: "结束",
              tint: .secondary,
              helpText: "结算并保存本次专注时长"
            ) {
              session.run {
                _ = try await session.workspace?.perform(.endFocus(id: focus.id, resumeHint: nil))
              }
            }

            if let taskID = focus.taskID, snapshot.item(.tasks, taskID)?.status == "todo" {
              flatTextPill(
                title: "完成任务",
                tint: .green,
                helpText: "勾选完成此任务并结算专注"
              ) {
                session.run {
                  _ = try await session.workspace?.perform(
                    .update(.tasks, id: taskID, fields: [.status: .string("done")]))
                }
              }
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          tint.opacity(colorScheme == .dark ? 0.13 : 0.07),
          in: .rect(cornerRadius: 10, style: .continuous)
        )
        .overlay(alignment: .bottomLeading) {
          if let progress {
            GeometryReader { geo in
              Capsule()
                .fill(goalReached ? Color.green.opacity(0.75) : tint.opacity(0.65))
                .frame(width: max(6, geo.size.width * progress), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
          }
        }
      }
    }

    private func flatTextPill(
      title: String,
      tint: Color,
      helpText: String,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(tint)
          .padding(.horizontal, 8)
          .padding(.vertical, 3.5)
          .background(
            (tint == .green ? Color.green : Color.primary).opacity(tint == .green ? 0.12 : 0.06),
            in: .rect(cornerRadius: 6, style: .continuous)
          )
      }
      .buttonStyle(.plain)
      .help(helpText)
    }

    // MARK: - 3. Clean Today Pending Tasks

    private func menuTaskRow(_ task: WorkspaceItem) -> some View {
      let isHovered = hoveredTaskID == task.id
      let isFocusing = session.focusStatus?.taskID == task.id
      return HStack(spacing: 9) {
        Button {
          session.run {
            _ = try await session.workspace?.perform(
              .update(.tasks, id: task.id, fields: [.status: .string("done")]))
          }
        } label: {
          Image(systemName: "circle")
            .font(.system(size: 13.5, weight: .light))
            .foregroundStyle(
              task.importance > 1 ? importanceColor(task.importance) : Color.secondary.opacity(0.75)
            )
        }
        .buttonStyle(.plain)
        .help("完成")

        Text(task.title)
          .font(.system(size: 13.5, weight: .regular))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if isFocusing {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
        } else if isHovered {
          Button {
            let goal = preferredGoalSeconds
            session.run {
              _ = try await session.workspace?.perform(
                .startFocus(taskID: task.id, goalSeconds: goal))
            }
          } label: {
            Image(systemName: "play.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 20, height: 20)
              .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("专注此任务")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5.5)
      .background(
        isHovered ? Color.primary.opacity(0.045) : .clear,
        in: .rect(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
      .onHover { hovering in
        hoveredTaskID = hovering ? task.id : (hoveredTaskID == task.id ? nil : hoveredTaskID)
      }
    }

    private func submitCapture() {
      let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !saving, !text.isEmpty, let store = session.workspace else { return }
      saving = true
      Task {
        defer { saving = false }
        do {
          if captureKind == .task {
            _ = try await store.perform(
              .create(
                .tasks,
                fields: [
                  .title: .string(text),
                  .plannedDate: plannedToday ? .string(Clock.day()) : .null,
                ]))
          } else {
            _ = try await store.perform(.create(.notes, fields: [.content: .string(text)]))
          }
          draft = ""
          plannedToday = true
          inputFocused = true
          flashCheck()
          session.scheduleSync()
        } catch {
          session.error = error.localizedDescription
        }
      }
    }

    private func flashCheck() {
      withAnimation(.easeOut(duration: 0.12)) { savedCheck = true }
      Task {
        try? await Task.sleep(for: .milliseconds(900))
        withAnimation(.easeOut(duration: 0.18)) { savedCheck = false }
      }
    }
  }
#endif
