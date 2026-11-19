#if os(macOS)
  import AppKit
  import SwiftUI

  private struct AssistantCapabilityCard: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let summary: String
    let sampleCommand: String?
  }

  private let assistantCapabilities: [AssistantCapabilityCard] = [
    .init(
      id: "task",
      symbol: "checkmark.circle",
      tint: .blue,
      title: "一句话记待办与提醒",
      summary: "自动识别日期、提醒时间与重要程度",
      sampleCommand: "明天下午三点提醒我交开题报告"
    ),
    .init(
      id: "voice",
      symbol: "mic",
      tint: .teal,
      title: "微信语音 & 灵感速记",
      summary: "直接按住发语音，或说「记条随手记…」",
      sampleCommand: "记条随手记：刚才想到的产品改进点子"
    ),
    .init(
      id: "timetable",
      symbol: "calendar",
      tint: .indigo,
      title: "发截图 / Excel 导课表",
      summary: "直接发教务课表图或表格，回复「确认」落库",
      sampleCommand: "查看我现在有哪些学期和课程"
    ),
    .init(
      id: "manage",
      symbol: "sparkles",
      tint: .orange,
      title: "查日程、管空间与专注",
      summary: "随时问今日安排、建自定义空间或开启专注",
      sampleCommand: "帮我建个「阅读」空间，再看看今天有什么待办"
    ),
  ]

  struct WeChatAssistantView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let isOnboarding: Bool
    var showTask: (String) -> Void
    var skipOnboarding: (() -> Void)? = nil

    @State private var started = false
    @State private var editingKey = false
    @State private var showingGuide = false
    @State private var baselineTaskID: String?
    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var pin = ""
    @State private var copiedCardID: String?
    @State private var hoveredCardID: String?
    @State private var confirmDisconnect = false
    @State private var celebrateScale: CGFloat = 0.55
    @State private var celebrateRingScale: CGFloat = 0.75
    @State private var celebrateRingOpacity: Double = 0.65
    @FocusState private var keyFocused: Bool

    private var assistant: WeChatAssistant { session.weChatAssistant }

    /// Only treat a task as a "live echoed test task" if it arrived during this guide session
    /// or wasn't stale from an old session before opening settings.
    private var liveEchoTask: WorkspaceItem? {
      guard let id = assistant.taskID, id != baselineTaskID else { return nil }
      return session.workspace?.snapshot.item(.tasks, id)
    }

    private enum Stage {
      case loading
      case welcome
      case pairing
      case keyForm
      case guide
      case dashboard
    }

    private var stage: Stage {
      if !assistant.ready { return .loading }
      if isOnboarding && !started && !assistant.connected { return .welcome }
      if !assistant.connected { return .pairing }
      if !assistant.hasKey || editingKey { return .keyForm }
      if showingGuide { return .guide }
      return .dashboard
    }

    private var activeStepIndex: Int? {
      switch stage {
      case .pairing: 1
      case .keyForm: editingKey ? nil : 2
      case .guide: 3
      default: nil
      }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 18) {
        if let step = activeStepIndex {
          stepProgressHeader(currentStep: step)
        }

        switch stage {
        case .loading:
          loadingStage
        case .welcome:
          welcomeStage
        case .pairing:
          pairingStage
        case .keyForm:
          keySetupStage
        case .guide:
          guideStage
        case .dashboard:
          dashboardStage
        }

        if stage != .welcome && stage != .guide, let issue = assistant.issue {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
              .foregroundStyle(.orange)
              .font(.subheadline)
            Text(issue)
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 9, style: .continuous))
        }

        Rectangle()
          .fill(WorkbenchDesign.line)
          .frame(height: 0.5)

        footerBar
      }
      .padding(24)
      .frame(width: 520)
      .background(WorkbenchDesign.canvas)
      .onAppear {
        baselineTaskID = assistant.taskID
      }
      .onChange(of: assistant.connected) { _, connected in
        pin = ""
        if connected && assistant.hasKey && !editingKey {
          baselineTaskID = assistant.taskID
          triggerCelebration()
          assistant.start()
        }
      }
      .onChange(of: assistant.verifying) { wasVerifying, verifying in
        if wasVerifying && !verifying && assistant.issue == nil && assistant.hasKey {
          let wasReplacingExisting = editingKey
          editingKey = false
          apiKey = ""
          if !wasReplacingExisting {
            baselineTaskID = assistant.taskID
            triggerCelebration()
          }
        }
      }
      .onDisappear { assistant.closeSetup() }
      .confirmationDialog("解除微信绑定？", isPresented: $confirmDisconnect) {
        Button("解绑并清除对话缓存", role: .destructive) {
          showingGuide = false
          Task { await assistant.disconnect() }
        }
      } message: {
        Text("此 Mac 将停止接收该微信消息，并清除本机临时对话记录；已写入随口记的待办、课程与笔记全部保留。")
      }
      .accessibilityIdentifier("wechat.assistant.sheet")
    }

    // MARK: - Top 3-Step Progress Strip

    private func stepProgressHeader(currentStep: Int) -> some View {
      let steps = [(1, "扫码绑微信"), (2, "配置 AI 引擎"), (3, "连接就绪")]
      return HStack(spacing: 8) {
        ForEach(steps, id: \.0) { index, label in
          let done = index < currentStep || (currentStep == 3 && index == 3)
          let active = index == currentStep
          HStack(spacing: 5) {
            ZStack {
              Circle()
                .fill(
                  done
                    ? Color.green.opacity(0.15)
                    : (active ? Color.accentColor.opacity(0.14) : WorkbenchDesign.fieldBackground)
                )
                .frame(width: 18, height: 18)
              if done {
                Image(systemName: "checkmark")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(.green)
              } else {
                Text("\(index)")
                  .font(.system(size: 10, weight: .semibold, design: .rounded))
                  .foregroundStyle(active ? Color.accentColor : .secondary)
              }
            }
            Text(label)
              .font(.system(size: 12, weight: active ? .medium : .regular))
              .foregroundStyle(active || done ? .primary : .tertiary)
          }
          if index < 3 {
            Rectangle()
              .fill(index < currentStep ? Color.green.opacity(0.35) : WorkbenchDesign.line)
              .frame(height: 1)
              .frame(maxWidth: 28)
          }
        }
        Spacer(minLength: 0)
      }
    }

    // MARK: - Stage 0: Welcome

    private var loadingStage: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("连接微信助手")
          .font(.system(size: 19, weight: .medium))
        Text("微信助手暂时无法初始化，请点击下方重试。")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }

    private var welcomeStage: some View {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 12) {
          SpeakNoteLogoBadge(size: 42)
          Image(systemName: "arrow.left.arrow.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
          ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.green.opacity(0.12))
              .frame(width: 42, height: 42)
            Image(systemName: "bubble.left.and.bubble.right.fill")
              .font(.system(size: 18))
              .foregroundStyle(.green)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("把微信变成你的「随口记」随身入口")
            .font(.system(size: 20, weight: .medium))
            .tracking(0.2)
          Text("无需安装额外手机插件，在微信聊天框发一句话、一段语音或一张课表图，即可自动归入这台 Mac 的工作台。")
            .font(.system(size: 13.5))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 10) {
          welcomeFeatureRow(
            symbol: "mic.fill",
            tint: .teal,
            title: "语音与文字秒记",
            detail: "走路闪过的念头或待办，发条微信直接落入「今日」或「随手记」"
          )
          welcomeFeatureRow(
            symbol: "calendar.badge.plus",
            tint: .indigo,
            title: "截图与 Excel 智能导课",
            detail: "发教务课表图片或表格，自动提取节次、周次与教室"
          )
          welcomeFeatureRow(
            symbol: "lock.shield",
            tint: .blue,
            title: "自有 Key 本机直连",
            detail: "使用你自己的 DeepSeek Key，数据与凭据仅保存在本机"
          )
        }
        .padding(14)
        .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 12, style: .continuous))
      }
    }

    private func welcomeFeatureRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(tint)
          .frame(width: 24, height: 24)
          .background(tint.opacity(0.12), in: .rect(cornerRadius: 6, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13.5, weight: .medium))
          Text(detail)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
      }
    }

    // MARK: - Stage 1: QR Pairing

    private var pairingStage: some View {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("用手机微信扫码绑定")
            .font(.system(size: 19, weight: .medium))
          Text("绑定后只响应你本人的微信消息，自动忽略群聊与他人消息。")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 12) {
          ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .fill(Color.white)
              .frame(width: 200, height: 200)
              .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .strokeBorder(WorkbenchDesign.line, lineWidth: 1)
              }

            if let data = assistant.qr, let image = NSImage(data: data) {
              Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 172, height: 172)
                .opacity(assistant.scanned ? 0.25 : 1)
                .accessibilityLabel("微信绑定二维码")

              if assistant.scanned && !assistant.needsPIN {
                VStack(spacing: 8) {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                  Text("已扫码\n请在手机微信点击确认")
                    .font(.system(size: 12.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black.opacity(0.8))
                }
              }
            } else if assistant.busy {
              VStack(spacing: 10) {
                ProgressView()
                  .controlSize(.regular)
                Text("正在获取二维码…")
                  .font(.caption)
                  .foregroundStyle(.gray)
              }
            } else {
              VStack(spacing: 8) {
                Image(systemName: "qrcode")
                  .font(.system(size: 32, weight: .light))
                  .foregroundStyle(.gray.opacity(0.6))
                Text("点击右下角生成二维码")
                  .font(.caption)
                  .foregroundStyle(.gray)
              }
            }
          }
          .frame(maxWidth: .infinity)

          if assistant.needsPIN {
            VStack(spacing: 8) {
              Text("请输入手机微信端显示的配对码")
                .font(.system(size: 13, weight: .medium))
              HStack(spacing: 8) {
                TextField("4–10 位数字配对码", text: $pin)
                  .textFieldStyle(.plain)
                  .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                  .multilineTextAlignment(.center)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .frame(width: 180)
                  .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 8))
                  .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchDesign.line, lineWidth: 1)
                  }
                  .onSubmit {
                    if validPIN {
                      assistant.submitPIN(pin)
                      pin = ""
                    }
                  }
                Button("确认") {
                  assistant.submitPIN(pin)
                  pin = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(!validPIN)
              }
            }
          } else if assistant.busy && assistant.qr != nil && !assistant.scanned {
            Text("打开手机微信「扫一扫」对准上方二维码")
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
      }
    }

    private var validPIN: Bool {
      (4...10).contains(pin.utf8.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    // MARK: - Stage 2: DeepSeek API Key Setup

    private var keySetupStage: some View {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 5) {
          Text(editingKey ? "更换 DeepSeek API Key" : "配置 DeepSeek API Key")
            .font(.system(size: 19, weight: .medium))
          HStack(spacing: 6) {
            Text("随口记通过 DeepSeek 模型理解自然语言与识别课表图片。")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            Link(
              "前往获取 Key ↗",
              destination: URL(string: "https://platform.deepseek.com/api_keys")!
            )
            .font(.system(size: 13, weight: .medium))
          }
        }

        HStack(spacing: 8) {
          Group {
            if revealKey {
              TextField("粘贴 sk-... 开头的 API Key", text: $apiKey)
            } else {
              SecureField("粘贴 sk-... 开头的 API Key", text: $apiKey)
            }
          }
          .textFieldStyle(.plain)
          .font(.system(size: 13.5, design: .monospaced))
          .focused($keyFocused)
          .disabled(assistant.verifying)
          .onSubmit {
            if !assistant.verifying && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              assistant.saveKey(apiKey)
            }
          }

          Button {
            revealKey.toggle()
          } label: {
            Image(systemName: revealKey ? "eye.slash" : "eye")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(revealKey ? "隐藏 Key" : "显示输入的 Key")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
              keyFocused ? Color.accentColor.opacity(0.55) : WorkbenchDesign.line,
              lineWidth: 1
            )
        }

        Text("凭据仅以当前用户只读权限（0600）保存在随口记本地目录中，不经过第三方中转，也不会触发 macOS 钥匙串弹窗。")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .lineSpacing(2.5)
          .fixedSize(horizontal: false, vertical: true)
      }
      .onAppear { keyFocused = true }
    }

    // MARK: - Stage 3: Animated Connection Celebration + Interactive Capability Guide

    private var guideStage: some View {
      VStack(alignment: .leading, spacing: 16) {
        // 1. Celebratory Hero Banner (Animated Spring Checkmark + Ripple, Zero Anxious Spinner!)
        HStack(spacing: 14) {
          ZStack {
            Circle()
              .strokeBorder(Color.green.opacity(celebrateRingOpacity), lineWidth: 2)
              .frame(width: 46, height: 46)
              .scaleEffect(celebrateRingScale)

            Circle()
              .fill(Color.green.opacity(0.14))
              .frame(width: 42, height: 42)
              .scaleEffect(celebrateScale)

            Image(systemName: "checkmark")
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(.green)
              .scaleEffect(celebrateScale)
          }
          .frame(width: 48, height: 48)

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
              Text("微信助手已连接就绪")
                .font(.system(size: 18, weight: .medium))
              HStack(spacing: 4) {
                Circle()
                  .fill(assistant.paused ? Color.orange : Color.green)
                  .frame(width: 6, height: 6)
                Text(assistant.paused ? "已暂停" : "实时监听已开启")
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(assistant.paused ? .orange : .green)
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 2.5)
              .background(
                (assistant.paused ? Color.orange : Color.green).opacity(0.10),
                in: .capsule
              )
            }

            Text("现在直接在手机微信里发消息就能同步，点选下方卡片可复制口令去试试：")
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
          }
        }

        // 2. 2x2 Capability Grid (Click any card to copy its sample prompt!)
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
          spacing: 10
        ) {
          ForEach(assistantCapabilities) { card in
            capabilityCardView(card)
          }
        }

        // 3. Non-Blocking Live Echo Strip (Zero Infinite Spinner!)
        if let task = liveEchoTask {
          HStack(spacing: 10) {
            Image(systemName: "party.popper.fill")
              .font(.system(size: 15))
              .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
              Text("收到你的微信测试啦！")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
              Text("「\(task.title)」已自动写入你的今日待办")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button("去今日查看 →") {
              showTask(task.id)
              completeAndDismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: .capsule)
          }
          .padding(12)
          .background(Color.green.opacity(0.08), in: .rect(cornerRadius: 11, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
          }
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let trialErr = assistant.trialIssue {
          HStack(spacing: 8) {
            Image(systemName: "info.circle")
              .foregroundStyle(.orange)
            Text(trialErr)
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 10))
        } else {
          HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            Text("保持随口记在后台打开即可接收消息；现在可以拿起手机试发一条，也可直接跳过。")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 10, style: .continuous))
        }
      }
      .animation(.snappy(duration: 0.25), value: liveEchoTask?.id)
    }

    private func capabilityCardView(_ card: AssistantCapabilityCard) -> some View {
      let copied = copiedCardID == card.id
      let hovered = hoveredCardID == card.id
      return Button {
        guard let sample = card.sampleCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sample, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copiedCardID = card.id }
        Task {
          try? await Task.sleep(for: .milliseconds(1400))
          if copiedCardID == card.id {
            withAnimation(.easeOut(duration: 0.2)) { copiedCardID = nil }
          }
        }
      } label: {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 7) {
            Image(systemName: card.symbol)
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(card.tint)
              .frame(width: 24, height: 24)
              .background(card.tint.opacity(0.12), in: .rect(cornerRadius: 6, style: .continuous))

            Text(card.title)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.primary)
              .lineLimit(1)

            Spacer(minLength: 0)

            if copied {
              Text("已复制")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.green)
            } else if hovered {
              Image(systemName: "doc.on.doc")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
          }

          Text(card.summary)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)

          if let sample = card.sampleCommand {
            Text("“\(sample)”")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(WorkbenchDesign.canvas.opacity(0.8), in: .rect(cornerRadius: 6))
          }
        }
        .padding(11)
        .background(
          hovered ? Color.primary.opacity(0.055) : WorkbenchDesign.fieldBackground,
          in: .rect(cornerRadius: 11, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(
              copied ? Color.green.opacity(0.45) : WorkbenchDesign.line,
              lineWidth: 1
            )
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { isHovering in
        hoveredCardID = isHovering ? card.id : (hoveredCardID == card.id ? nil : hoveredCardID)
      }
      .help("点击复制示例消息")
    }

    // MARK: - Stage 4: Connected Status Dashboard (Re-opening from Sidebar)

    private var dashboardStage: some View {
      let statusColor: Color =
        assistant.online ? .green : (assistant.running ? .orange : .secondary)
      let statusLabel =
        assistant.online ? "在线监听中" : (assistant.running ? "正在连接通道…" : (assistant.paused ? "已暂停接收" : "未启动"))

      return VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .fill(statusColor.opacity(0.12))
              .frame(width: 42, height: 42)
            Image(systemName: "bubble.left.and.bubble.right.fill")
              .font(.system(size: 18))
              .foregroundStyle(statusColor)
          }

          VStack(alignment: .leading, spacing: 3) {
            Text("微信助手")
              .font(.system(size: 18, weight: .medium))
            HStack(spacing: 6) {
              Circle().fill(statusColor).frame(width: 6.5, height: 6.5)
              Text(statusLabel)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            }
          }

          Spacer()

          Button(assistant.running ? "暂停接收" : "恢复接收") {
            Task { await assistant.setPaused(assistant.running) }
          }
          .disabled(assistant.stopping)
        }

        VStack(spacing: 0) {
          dashboardRow(label: "微信连接", value: "已绑定专属账号") {
            Button("解绑…", role: .destructive) { confirmDisconnect = true }
              .buttonStyle(.plain)
              .font(.system(size: 12.5))
              .foregroundStyle(.red.opacity(0.85))
              .disabled(assistant.stopping)
          }

          Rectangle().fill(WorkbenchDesign.line).frame(height: 0.5).padding(.horizontal, 12)

          dashboardRow(label: "AI 模型引擎", value: "DeepSeek 已就绪") {
            HStack(spacing: 12) {
              Button("更换 Key") { editingKey = true }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.accentColor)
              Button("清除") {
                Task { await assistant.clearKey() }
              }
              .buttonStyle(.plain)
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
            }
            .disabled(assistant.stopping)
          }
        }
        .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WorkbenchDesign.line, lineWidth: 1)
        }

        Button {
          baselineTaskID = assistant.taskID
          triggerCelebration()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "sparkles")
              .font(.system(size: 13))
              .foregroundStyle(Color.accentColor)
            Text("查看微信指令玩法指南与可复制示例")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: 10, style: .continuous))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Text("提示：随口记在后台或菜单栏常驻期间均可实时接收并处理你的微信消息。")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
      }
    }

    private func dashboardRow<Trailing: View>(
      label: String,
      value: String,
      @ViewBuilder trailing: () -> Trailing
    ) -> some View {
      HStack {
        Text(label)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.primary)
          .padding(.leading, 6)
        Spacer()
        trailing()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
    }

    // MARK: - Unified Footer Bar

    private var footerBar: some View {
      HStack(spacing: 12) {
        switch stage {
        case .loading:
          Button("关闭") { completeAndDismiss() }
          Spacer()
          if let store = session.workspace, let directory = session.location?.directory {
            Button("重试") {
              assistant.configure(session: session, store: store, directory: directory)
            }
            .buttonStyle(.borderedProminent)
          }

        case .welcome:
          Button("暂不开启，直接进入") { completeAndDismiss() }
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button("开始连接 →") {
            started = true
            assistant.connect()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)

        case .pairing:
          Button(isOnboarding ? "跳过，稍后设置" : "取消") {
            completeAndDismiss()
          }
          .keyboardShortcut(.cancelAction)
          Spacer()
          if !assistant.busy {
            Button(assistant.issue == nil ? "生成二维码" : "重新获取二维码") {
              started = true
              assistant.connect()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          }

        case .keyForm:
          if editingKey {
            Button("取消更换") {
              editingKey = false
              apiKey = ""
            }
            .disabled(assistant.verifying)
          } else {
            HStack(spacing: 12) {
              Button(isOnboarding ? "稍后配置" : "关闭") {
                completeAndDismiss()
              }
              .disabled(assistant.verifying)

              Button("重绑微信…") { confirmDisconnect = true }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .disabled(assistant.verifying || assistant.stopping)
            }
          }

          Spacer()

          Button {
            assistant.saveKey(apiKey)
          } label: {
            HStack(spacing: 6) {
              if assistant.verifying {
                ProgressView()
                  .controlSize(.small)
              }
              Text(assistant.verifying ? "正在验证连接…" : "验证并连接")
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            assistant.verifying
              || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )

        case .guide:
          Button("跳过引导") {
            completeAndDismiss()
          }
          .keyboardShortcut(.cancelAction)

          Spacer()

          if let task = liveEchoTask {
            Button("去「今日」查看 →") {
              showTask(task.id)
              completeAndDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          } else {
            Button("开始使用") {
              completeAndDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          }

        case .dashboard:
          Spacer()
          Button("完成") {
            completeAndDismiss()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
      }
      .controlSize(.regular)
    }

    private func triggerCelebration() {
      celebrateScale = 0.5
      celebrateRingScale = 0.72
      celebrateRingOpacity = 0.75
      showingGuide = true
      withAnimation(.spring(response: 0.44, dampingFraction: 0.66)) {
        celebrateScale = 1.0
      }
      withAnimation(.easeOut(duration: 0.75)) {
        celebrateRingScale = 1.38
        celebrateRingOpacity = 0.0
      }
    }

    private func completeAndDismiss() {
      if let skipOnboarding {
        skipOnboarding()
      } else {
        dismiss()
      }
    }
  }
#endif
