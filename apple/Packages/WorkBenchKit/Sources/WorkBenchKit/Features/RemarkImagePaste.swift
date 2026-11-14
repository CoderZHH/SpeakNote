import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum RemarkImagePaste {
  static let contentTypes: [UTType] = [.image, .fileURL]
  private static let maximum = 100 * 1024 * 1024

  @MainActor static func load(_ provider: NSItemProvider) async throws -> (data: Data, name: String)? {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      let types = provider.registeredContentTypes.filter { $0.conforms(to: .image) }
      let type = types.first { $0 == .png || $0 == .jpeg } ?? types.first ?? .image
      let data = try await representation(provider, type: type)
      return try await Task.detached {
        (try attachmentData(data), "粘贴的图片")
      }.value
    }
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
      let url = URL(dataRepresentation: try await representation(provider, type: .fileURL), relativeTo: nil),
      url.isFileURL
    else { return nil }
    return try await Task.detached { () throws -> (data: Data, name: String)? in
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, values.contentType?.conforms(to: .image) == true
      else { return nil }
      try require((1...maximum).contains(values.fileSize ?? 0), "图片超过允许大小")
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      return (try attachmentData(data), url.lastPathComponent)
    }.value
  }

  @MainActor private static func representation(_ provider: NSItemProvider, type: UTType) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: error ?? WorkBenchError("无法读取剪贴板图片")) }
      }
    }
  }

  private static func attachmentData(_ data: Data) throws -> Data {
    try require(!data.isEmpty && data.count <= maximum, "图片超过允许大小")
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
      type.conforms(to: .image), CGImageSourceGetCount(source) > 0
    else { throw WorkBenchError("无法读取剪贴板图片") }
    if ["png", "jpeg", "jpg", "webp", "gif", "heic", "heif", "avif"].contains(
      type.preferredFilenameExtension ?? ""
    ) { return data }

    // macOS clipboard images may be TIFF. Re-encode unsupported types as a bounded PNG.
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    let output = NSMutableData()
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else { throw WorkBenchError("无法转换剪贴板图片") }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "无法转换剪贴板图片")
    return output as Data
  }
}

extension View {
  @ViewBuilder func remarkImagePaste(perform: (([NSItemProvider]) -> Void)?) -> some View {
    #if os(macOS)
      if let perform {
        onPasteCommand(of: RemarkImagePaste.contentTypes, perform: perform)
      } else {
        self
      }
    #else
      self
    #endif
  }
}

#if os(iOS)
  import UIKit

  /// Keeps UIKit's editing menu and routes image paste items to the existing attachment store.
  struct RemarkTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Environment(\.isEnabled) private var enabled
    let placeholder: String
    let identifier: String
    let pasteImages: ([NSItemProvider]) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.delegate = context.coordinator
      view.pasteDelegate = context.coordinator
      let configuration = view.pasteConfiguration
        ?? UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.url.identifier])
      configuration.addAcceptableTypeIdentifiers([UTType.image.identifier])
      view.pasteConfiguration = configuration
      view.font = .preferredFont(forTextStyle: .subheadline)
      view.adjustsFontForContentSizeCategory = true
      view.textColor = .label
      view.textContainerInset = .zero
      view.textContainer.lineFragmentPadding = 0
      view.backgroundColor = .clear
      view.accessibilityIdentifier = identifier
      view.accessibilityLabel = placeholder
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      let coordinator = context.coordinator
      coordinator.parent = self
      if view.markedTextRange == nil, view.text != text { view.text = text }
      view.isEditable = enabled
      if focused != view.isFirstResponder {
        Task { @MainActor [weak view, weak coordinator] in
          guard let view, let coordinator, view.window != nil else { return }
          if coordinator.parent.focused && !view.isFirstResponder { view.becomeFirstResponder() }
          if !coordinator.parent.focused && view.isFirstResponder { view.resignFirstResponder() }
        }
      }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
      guard let width = proposal.width, width > 0 else { return nil }
      let line = uiView.font?.lineHeight ?? 18
      let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      return CGSize(width: width, height: min(ceil(line * 20), max(ceil(line), fitted.height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
      var parent: RemarkTextInput
      init(_ parent: RemarkTextInput) { self.parent = parent }

      func textViewDidBeginEditing(_ view: UITextView) { parent.focused = true }

      func textViewDidEndEditing(_ view: UITextView) {
        view.unmarkText()
        parent.text = view.text
        parent.focused = false
        parent.onEnd()
      }

      func textViewDidChange(_ view: UITextView) {
        if view.markedTextRange == nil { parent.text = view.text }
      }

      func textPasteConfigurationSupporting(
        _ supporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem
      ) {
        let provider = item.itemProvider
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
          item.setNoResult()
          parent.pasteImages([provider])
        } else {
          item.setDefaultResult()
        }
      }
    }
  }
#endif
