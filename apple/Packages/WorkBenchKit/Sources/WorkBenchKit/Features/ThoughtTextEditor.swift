import SwiftUI

// One native text document, one undo history and one shared autosave buffer.
// Only presentation attributes change; the original content/line breaks stay intact.
#if os(iOS)
  import UIKit
  struct ThoughtTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.delegate = context.coordinator
      view.backgroundColor = .clear
      view.textContainerInset = UIEdgeInsets(top: 8, left: 3, bottom: 16, right: 3)
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
      private var styledText: String?
      private var styledSize: CGFloat = 0
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
      func style(_ view: UITextView) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        guard styledText != view.text || styledSize != body.pointSize else { return }
        styledText = view.text
        styledSize = body.pointSize
        let title = UIFont.preferredFont(forTextStyle: .title2)
        let bold = UIFont(
          descriptor: title.fontDescriptor.withSymbolicTraits(.traitBold) ?? title.fontDescriptor,
          size: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        view.textStorage.beginEditing()
        view.textStorage.addAttributes(
          [.font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph],
          range: NSRange(location: 0, length: view.textStorage.length))
        let heading = (view.text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        if heading.length > 0 { view.textStorage.addAttribute(.font, value: bold, range: heading) }
        view.textStorage.endEditing()
        typing(view)
      }
      func typing(_ view: UITextView) {
        let end = (view.text as NSString).rangeOfCharacter(from: .newlines).location
        let title = UIFont.preferredFont(forTextStyle: .title2)
        let bold = UIFont(
          descriptor: title.fontDescriptor.withSymbolicTraits(.traitBold) ?? title.fontDescriptor,
          size: 0)
        view.typingAttributes = [
          .font: view.selectedRange.location <= end
            ? bold : UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label,
        ]
      }
    }
  }
#else
  import AppKit
  struct ThoughtTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSTextView.scrollableTextView()
      scroll.hasVerticalScroller = true
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
      view.textContainerInset = NSSize(width: 3, height: 8)
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
      private var styledText: String?
      private var styledSize: CGFloat = 0
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
      func style(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let body = NSFont.preferredFont(forTextStyle: .body)
        guard styledText != view.string || styledSize != body.pointSize else { return }
        styledText = view.string
        styledSize = body.pointSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        storage.beginEditing()
        storage.addAttributes(
          [
            .font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
          ], range: NSRange(location: 0, length: storage.length))
        let heading = (view.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        if heading.length > 0 { storage.addAttribute(.font, value: titleFont, range: heading) }
        storage.endEditing()
        typing(view)
      }
      var titleFont: NSFont {
        NSFontManager.shared.convert(
          NSFont.preferredFont(forTextStyle: .title2), toHaveTrait: .boldFontMask)
      }
      func typing(_ view: NSTextView) {
        let end = (view.string as NSString).rangeOfCharacter(from: .newlines).location
        view.typingAttributes = [
          .font: view.selectedRange().location <= end
            ? titleFont : NSFont.preferredFont(forTextStyle: .body),
          .foregroundColor: NSColor.labelColor,
        ]
      }
    }
  }
#endif
