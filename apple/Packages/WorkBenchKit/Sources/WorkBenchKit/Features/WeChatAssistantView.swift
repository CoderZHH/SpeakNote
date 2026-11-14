#if os(macOS)
import SwiftUI

struct WeChatAssistantView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let welcome: Bool
  let resumeTrial: Bool
  var showTask: (String) -> Void
  @State private var started = false
  @State private var editingKey = false
  @State private var trying = false
  @State private var apiKey = ""
  @State private var pin = ""
  @State private var confirmDisconnect = false
  @FocusState private var keyFocused: Bool

  private var assistant: WeChatAssistant { session.weChatAssistant }
  private var savedTask: WorkspaceItem? {
    assistant.taskID.flatMap { session.workspace?.snapshot.item(.tasks, $0) }
  }
  private var showsWelcome: Bool { welcome && !started }
  private var showsTrial: Bool { trying || (resumeTrial && assistant.connected && assistant.hasKey) }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.group) {
      header
      if showsWelcome {
        Text("连接你的微信并配置 DeepSeek。发一条消息，就能在「今日」看到待办。")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if !assistant.ready {
        Text("微信助手暂时无法初始化。").foregroundStyle(.secondary)
      } else if !assistant.connected {
        pairing
      } else if !assistant.hasKey || editingKey {
        keyForm
      } else if showsTrial {
        firstTask
      } else {
        connectionSettings
      }
      if !showsWelcome, let issue = assistant.issue {
        Label(issue, systemImage: "exclamationmark.circle")
          .font(.callout).foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      footer
    }
    .padding(WorkbenchDesign.sheetInset)
    .frame(width: WorkbenchDesign.sheetWidth)
    .onChange(of: assistant.connected) { _, connected in
      pin = ""
      if connected && assistant.hasKey && (started || trying) {
        trying = true
        assistant.start()
      }
    }
    .onChange(of: assistant.verifying) { _, verifying in
      if !verifying && assistant.issue == nil && assistant.hasKey {
        editingKey = false
        apiKey = ""
      }
    }
    .onDisappear { assistant.closeSetup() }
    .confirmationDialog("解除微信绑定？", isPresented: $confirmDisconnect) {
      Button("断开并清除本机对话", role: .destructive) {
        trying = false
        Task { await assistant.disconnect() }
      }
    } message: {
      Text("此 Mac 将停止处理该微信的消息，并清除助手的本机对话记录。已保存的待办会保留。")
    }
    .accessibilityIdentifier("wechat.assistant.sheet")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.small) {
      Image(systemName: showsWelcome ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
        .font(.title).foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
      if !showsWelcome, assistant.ready, started || showsTrial {
        Text(step).font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }

  private var title: String {
    if showsWelcome { return "在微信里发一句话，待办就出现在 WorkBench" }
    if !assistant.connected && assistant.ready { return "扫码连接微信" }
    if assistant.ready && (!assistant.hasKey || editingKey) { return "配置 DeepSeek" }
    if showsTrial { return savedTask == nil ? "试着发一条待办" : "第一条待办已保存" }
    return "微信助手"
  }

  private var step: String {
    if !assistant.connected { return "第 1 步，共 3 步" }
    if !assistant.hasKey || editingKey { return "第 2 步，共 3 步" }
    return "第 3 步，共 3 步"
  }

  private var pairing: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      Text("用手机微信扫描二维码，在手机上确认连接。")
        .foregroundStyle(.secondary)
      if let data = assistant.qr, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable().interpolation(.none).scaledToFit()
          .padding(WorkbenchDesign.Space.medium).frame(width: 204, height: 204)
          .background(.white, in: .rect(cornerRadius: WorkbenchDesign.radius))
          .frame(maxWidth: .infinity)
          .accessibilityLabel("微信绑定二维码")
      } else if assistant.busy {
        ProgressView("正在生成二维码…").frame(maxWidth: .infinity, minHeight: 150)
      }
      if assistant.needsPIN {
        Text("输入手机微信显示的配对码。")
        TextField("配对码", text: $pin)
          .workspaceInput()
          .onSubmit { if validPIN { assistant.submitPIN(pin); pin = "" } }
        Button("提交配对码") { assistant.submitPIN(pin); pin = "" }
          .disabled(!validPIN)
      } else if assistant.busy && assistant.qr != nil {
        Label(assistant.scanned ? "已扫码，请在手机上确认" : "等待扫码", systemImage: "qrcode")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var validPIN: Bool {
    (4...10).contains(pin.utf8.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
  }

  private var keyForm: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      Text("使用你自己的 DeepSeek API Key。验证会发送一条固定测试消息，Key 会保存在这台 Mac 的钥匙串。")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Link("获取 DeepSeek API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
      SecureField("DeepSeek API Key", text: $apiKey)
        .workspaceInput(focused: keyFocused)
        .focused($keyFocused)
        .disabled(assistant.verifying)
      Text("助手启用后，微信消息、发送的图片和回答所需的工作区内容可能会发给 DeepSeek。")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if assistant.verifying { ProgressView("正在验证 DeepSeek…").controlSize(.small) }
      if editingKey {
        Button("取消更换") { editingKey = false; apiKey = "" }.disabled(assistant.verifying)
      } else {
        Button("解绑微信…") { confirmDisconnect = true }.disabled(assistant.verifying || assistant.stopping)
      }
    }
  }

  private var firstTask: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      if let savedTask {
        Label(savedTask.title, systemImage: "checkmark.circle.fill")
          .font(.headline).foregroundStyle(.tint).textSelection(.enabled)
        Text("已写入你的工作台。").foregroundStyle(.secondary)
      } else {
        Text("打开微信里的助手对话，发一条你想记下的待办。")
        HStack {
          Button("更换 API Key") { editingKey = true }
          Button("解绑微信…") { confirmDisconnect = true }
            .disabled(assistant.stopping)
        }
        Text("帮我记条待办：周五前交报告")
          .font(.headline).textSelection(.enabled)
          .padding(WorkbenchDesign.Space.medium)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchDesign.fieldBackground, in: .rect(cornerRadius: WorkbenchDesign.fieldRadius))
        if assistant.running {
          ProgressView(assistant.online ? "等待微信消息…" : "正在连接微信…").controlSize(.small)
        } else if assistant.paused {
          Text("助手已暂停。").foregroundStyle(.secondary)
        }
        if let issue = assistant.trialIssue {
          Text(issue).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        keepOpen
      }
    }
  }

  private var connectionSettings: some View {
    VStack(alignment: .leading, spacing: WorkbenchDesign.Space.medium) {
      LabeledContent("微信", value: "已绑定")
      LabeledContent("DeepSeek", value: "已配置")
      LabeledContent("助手", value: assistant.online ? "在线" : assistant.running ? "连接中" : "已停止")
      keepOpen
      HStack {
        Button(assistant.running ? "暂停接收" : "启动助手") {
          Task { await assistant.setPaused(assistant.running) }
        }.disabled(assistant.stopping)
        Button("更换 API Key") { editingKey = true }
        Button("清除 API Key") { Task { await assistant.clearKey() } }
          .disabled(assistant.stopping)
        Button("解绑微信…") { confirmDisconnect = true }.disabled(assistant.stopping)
      }
    }
  }

  private var keepOpen: some View {
    Text("接收微信消息时，请保持 WorkBench 打开。")
      .font(.callout).foregroundStyle(.secondary)
  }

  private var footer: some View {
    HStack {
      Button(showsWelcome ? "先看看工作台" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      Spacer()
      if showsWelcome {
        Button("连接微信") {
          started = true
          trying = true
          assistant.connect()
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(!assistant.ready)
      } else if assistant.ready && !assistant.connected && !assistant.busy {
        Button(assistant.issue == nil ? "生成二维码" : "重新生成二维码") {
          started = true
          trying = true
          assistant.connect()
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      } else if assistant.connected && (!assistant.hasKey || editingKey) {
        Button("验证并继续") {
          trying = !assistant.hasKey || trying
          assistant.saveKey(apiKey)
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(assistant.verifying || apiKey.isEmpty)
      } else if showsTrial, let savedTask {
        Button("在今日查看") {
          showTask(savedTask.id)
          dismiss()
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      } else if showsTrial && !assistant.running && !assistant.stopping {
        Button("启动助手") { Task { await assistant.setPaused(false) } }
          .buttonStyle(.borderedProminent)
      }
    }
  }
}
#endif
