import SwiftUI

enum ThoughtFontStyle: String, CaseIterable, Identifiable {
  case sans
  case serif
  case rounded

  var id: String { rawValue }

  var label: String {
    switch self {
    case .sans: "人文"
    case .serif: "书卷"
    case .rounded: "温润"
    }
  }

  var samplePreviewFont: Font {
    switch self {
    case .sans: .system(size: 14, weight: .medium, design: .default)
    case .serif: .system(size: 14, weight: .medium, design: .serif)
    case .rounded: .system(size: 14, weight: .medium, design: .rounded)
    }
  }

  func placeholderTitleFont(scale: ThoughtFontScale) -> Font {
    let pt = scale.titleSize
    switch self {
    case .sans: return .system(size: pt, weight: .medium, design: .default)
    case .serif: return .custom("Songti SC", size: pt).weight(.semibold)
    case .rounded: return .system(size: pt, weight: .medium, design: .rounded)
    }
  }
}

enum ThoughtFontScale: Int, CaseIterable, Identifiable {
  case standard = 0
  case relaxed = 1
  case large = 2

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .standard: "标准"
    case .relaxed: "舒展"
    case .large: "大字"
    }
  }

  var bodySize: CGFloat {
    #if os(macOS)
      switch self {
      case .standard: 15.5
      case .relaxed: 16.5
      case .large: 18.0
      }
    #else
      switch self {
      case .standard: 16.5
      case .relaxed: 17.5
      case .large: 19.0
      }
    #endif
  }

  var titleSize: CGFloat {
    switch self {
    case .standard: 22.0
    case .relaxed: 24.0
    case .large: 26.0
    }
  }
}

// One native text document, one undo history and one shared autosave buffer.
// Only presentation attributes change; the original content/line breaks stay intact.
#if os(iOS)
  import UIKit

  private func resolveUIFont(style: ThoughtFontStyle, size: CGFloat, isTitle: Bool) -> UIFont {
    let weight: UIFont.Weight = isTitle ? .semibold : .regular
    switch style {
    case .sans:
      return UIFont.systemFont(ofSize: size, weight: weight)
    case .serif:
      if let songti = UIFont(name: isTitle ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size) {
        return songti
      }
      let base = UIFont.systemFont(ofSize: size, weight: weight)
      if let desc = base.fontDescriptor.withDesign(.serif) {
        return UIFont(descriptor: desc, size: size)
      }
      return base
    case .rounded:
      let base = UIFont.systemFont(ofSize: size, weight: weight)
      if let desc = base.fontDescriptor.withDesign(.rounded) {
        return UIFont(descriptor: desc, size: size)
      }
      return base
    }
  }

  struct ThoughtTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var fontStyle: ThoughtFontStyle = .sans
    var fontScale: ThoughtFontScale = .standard

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.delegate = context.coordinator
      view.backgroundColor = .clear
      view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 32, right: 0)
      view.textContainer.lineFragmentPadding = 0
      view.adjustsFontForContentSizeCategory = true
      view.keyboardDismissMode = .interactive
      view.accessibilityIdentifier = "thought.content"
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.parent = self
      if !focused && view.isFirstResponder {
        view.unmarkText()
        let committed = view.text ?? ""
        view.resignFirstResponder()
        context.coordinator.parent.text = committed
        return
      }
      guard view.markedTextRange == nil else { return }
      if view.text != text { view.text = text }
      context.coordinator.style(view)
      if focused && !view.isFirstResponder && view.window != nil { view.becomeFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      private var styledKey = ""
      var parent: ThoughtTextEditor
      init(_ parent: ThoughtTextEditor) { self.parent = parent }

      func textViewDidBeginEditing(_ view: UITextView) { parent.focused = true }
      func textViewDidEndEditing(_ view: UITextView) {
        view.unmarkText()
        parent.text = view.text
        parent.focused = false
      }
      func textViewDidChange(_ view: UITextView) {
        guard view.markedTextRange == nil else { return }
        parent.text = view.text
        style(view)
      }
      func textViewDidChangeSelection(_ view: UITextView) {
        guard view.markedTextRange == nil else { return }
        typing(view)
      }

      @MainActor func style(_ view: UITextView) {
        let key = "\(view.text ?? "")|\(parent.fontStyle.rawValue)|\(parent.fontScale.rawValue)"
        guard styledKey != key else { return }
        styledKey = key

        let bodyFont = resolveUIFont(
          style: parent.fontStyle, size: parent.fontScale.bodySize, isTitle: false)
        let headingFont = resolveUIFont(
          style: parent.fontStyle, size: parent.fontScale.titleSize, isTitle: true)

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 7.5
        bodyParagraph.paragraphSpacing = 6

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineSpacing = 5
        headingParagraph.paragraphSpacing = 12

        view.textStorage.beginEditing()
        let fullRange = NSRange(location: 0, length: view.textStorage.length)
        view.textStorage.addAttributes(
          [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: bodyParagraph,
            .kern: 0.25,
          ],
          range: fullRange
        )
        let heading = (view.text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        if heading.length > 0 {
          view.textStorage.addAttributes(
            [
              .font: headingFont,
              .paragraphStyle: headingParagraph,
              .kern: 0.35,
            ],
            range: heading
          )
        }
        view.textStorage.endEditing()
        typing(view)
      }

      @MainActor func typing(_ view: UITextView) {
        let end = (view.text as NSString).rangeOfCharacter(from: .newlines).location
        let inHeading = view.selectedRange.location <= end
        let font = resolveUIFont(
          style: parent.fontStyle,
          size: inHeading ? parent.fontScale.titleSize : parent.fontScale.bodySize,
          isTitle: inHeading
        )
        let para = NSMutableParagraphStyle()
        para.lineSpacing = inHeading ? 5 : 7.5
        para.paragraphSpacing = inHeading ? 12 : 6
        view.typingAttributes = [
          .font: font,
          .foregroundColor: UIColor.label,
          .paragraphStyle: para,
          .kern: inHeading ? 0.35 : 0.25,
        ]
      }
    }
  }
#else
  import AppKit

  private func resolveNSFont(style: ThoughtFontStyle, size: CGFloat, isTitle: Bool) -> NSFont {
    let weight: NSFont.Weight = isTitle ? .medium : .regular
    switch style {
    case .sans:
      return NSFont.systemFont(ofSize: size, weight: weight)
    case .serif:
      if let songti = NSFont(name: isTitle ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size) {
        return songti
      }
      let base = NSFont.systemFont(ofSize: size, weight: weight)
      if let desc = base.fontDescriptor.withDesign(.serif),
        let designed = NSFont(descriptor: desc, size: size)
      {
        return designed
      }
      return base
    case .rounded:
      let base = NSFont.systemFont(ofSize: size, weight: weight)
      if let desc = base.fontDescriptor.withDesign(.rounded),
        let designed = NSFont(descriptor: desc, size: size)
      {
        return designed
      }
      return base
    }
  }

  struct ThoughtTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var fontStyle: ThoughtFontStyle = .sans
    var fontScale: ThoughtFontScale = .standard

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSTextView.scrollableTextView()
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.drawsBackground = false
      guard let view = scroll.documentView as? NSTextView else {
        preconditionFailure("Missing native text view")
      }
      view.isRichText = false
      view.isAutomaticQuoteSubstitutionEnabled = false
      view.drawsBackground = false
      view.minSize = .zero
      view.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      view.isVerticallyResizable = true
      view.isHorizontallyResizable = false
      view.autoresizingMask = [.width]
      view.textContainer?.widthTracksTextView = true
      view.textContainer?.lineFragmentPadding = 0
      view.textContainerInset = NSSize(width: 0, height: 10)
      view.insertionPointColor = .controlAccentColor
      view.delegate = context.coordinator
      view.allowsUndo = true
      view.setAccessibilityIdentifier("thought.content")
      scroll.documentView = view
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      context.coordinator.parent = self
      guard let view = scroll.documentView as? NSTextView, !view.hasMarkedText() else { return }
      if view.string != text { view.string = text }
      context.coordinator.style(view)
      if focused, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
      private var styledKey = ""
      var parent: ThoughtTextEditor
      init(_ parent: ThoughtTextEditor) { self.parent = parent }

      func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
      func textDidEndEditing(_ notification: Notification) { parent.focused = false }
      func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
        parent.text = view.string
        style(view)
      }
      func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
        typing(view)
      }

      @MainActor func style(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let key = "\(view.string)|\(parent.fontStyle.rawValue)|\(parent.fontScale.rawValue)"
        guard styledKey != key else { return }
        styledKey = key

        let bodyFont = resolveNSFont(
          style: parent.fontStyle, size: parent.fontScale.bodySize, isTitle: false)
        let headingFont = resolveNSFont(
          style: parent.fontStyle, size: parent.fontScale.titleSize, isTitle: true)

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 7.5
        bodyParagraph.paragraphSpacing = 6

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineSpacing = 5
        headingParagraph.paragraphSpacing = 12

        storage.beginEditing()
        storage.addAttributes(
          [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bodyParagraph,
            .kern: 0.25,
          ],
          range: NSRange(location: 0, length: storage.length)
        )
        let heading = (view.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        if heading.length > 0 {
          storage.addAttributes(
            [
              .font: headingFont,
              .paragraphStyle: headingParagraph,
              .kern: 0.35,
            ],
            range: heading
          )
        }
        storage.endEditing()
        typing(view)
      }

      @MainActor func typing(_ view: NSTextView) {
        let end = (view.string as NSString).rangeOfCharacter(from: .newlines).location
        let inHeading = view.selectedRange().location <= end
        let font = resolveNSFont(
          style: parent.fontStyle,
          size: inHeading ? parent.fontScale.titleSize : parent.fontScale.bodySize,
          isTitle: inHeading
        )
        let para = NSMutableParagraphStyle()
        para.lineSpacing = inHeading ? 5 : 7.5
        para.paragraphSpacing = inHeading ? 12 : 6
        view.typingAttributes = [
          .font: font,
          .foregroundColor: NSColor.labelColor,
          .paragraphStyle: para,
          .kern: inHeading ? 0.35 : 0.25,
        ]
      }
    }
  }
#endif
