import SwiftUI
import UIKit

/// A fixed editing area keeps UIKit in one layout mode during typing and paste.
struct JournalTextEditor: View {
    @Binding var text: String
    @Binding var focused: Bool
    let editable: Bool
    let accessibilityName: String
    var placeholder: LocalizedStringKey = "Buradan başla…"
    var accessibilityID = "journal-editor"
    @AppStorage("daily.writing.appearance") private var appearance = WritingAppearance.neon.rawValue
    @AppStorage("daily.writing.serif") private var serif = false
    @AppStorage("daily.writing.size") private var writingSize = 21.0
    @AppStorage("daily.writing.spacing") private var writingSpacing = 7.0
    private var theme: WritingAppearance { WritingAppearance(rawValue:appearance) ?? .neon }

    var body: some View {
        JournalTextView(text:$text,focused:$focused,editable:editable,accessibilityName:accessibilityName,
            accessibilityID:accessibilityID,
            fontSize:writingSize,spacing:writingSpacing,serif:serif,ink:UIColor(theme.ink),
            caret:theme == .night ? .cyan : UIColor(DailyTheme.cobalt))
            .overlay(alignment: .topLeading) {
                Text(placeholder).font(.system(size:writingSize,design:serif ? .serif : .default))
                    .foregroundStyle(theme.ink.opacity(0.45)).padding(.top,10)
                    .opacity(text.isEmpty ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(maxWidth:.infinity,alignment:.topLeading)
    }
}

struct JournalTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let editable: Bool
    let accessibilityName: String
    let accessibilityID: String
    let fontSize,spacing: Double
    let serif: Bool
    let ink,caret: UIColor
    var viewportHeight: CGFloat = 320

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context)->UITextView {
        // Use one layout engine and retain the view as the keyboard changes the viewport.
        let view = UITextView(usingTextLayoutManager: false)
        view.delegate=context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.keyboardDismissMode = .interactive
        view.contentInset = .zero
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset=UIEdgeInsets(top:10,left:0,bottom:12,right:0)
        view.textContainer.lineFragmentPadding=0
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        view.accessibilityIdentifier=accessibilityID
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.accessibilityLabel=accessibilityName
        if view.isEditable != editable { view.isEditable = editable }
        if view.tintColor != caret { view.tintColor = caret }
        let typography="\(fontSize):\(spacing):\(serif):\(view.traitCollection.preferredContentSizeCategory.rawValue)"
        let changedStyle = coordinator.typography != typography || coordinator.ink?.isEqual(ink) != true
        // A view refresh that only echoes the previous model value must not replace in-flight UIKit input.
        let replaceText = view.text != text && (coordinator.modelText != text || !view.isFirstResponder)
        if view.markedTextRange == nil && (replaceText || changedStyle) {
            let base=UIFont.systemFont(ofSize:fontSize)
            let descriptor=serif ? base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor : base.fontDescriptor
            let font=UIFontMetrics(forTextStyle:.body).scaledFont(for:UIFont(descriptor:descriptor,size:fontSize),
                compatibleWith:view.traitCollection)
            let paragraph=NSMutableParagraphStyle()
            paragraph.lineSpacing=spacing
            let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:ink,.paragraphStyle:paragraph]
            let selection = view.selectedRange
            coordinator.applyingText = true
            if replaceText {
                view.attributedText = NSAttributedString(string: text, attributes: attributes)
                coordinator.modelText = text
            } else if view.textStorage.length > 0 {
                view.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage.length))
            }
            if replaceText && selection.location != NSNotFound {
                let count = view.textStorage.length
                let start = min(selection.location, count)
                view.selectedRange = NSRange(location: start, length: min(selection.length, count - start))
            }
            view.typingAttributes = attributes
            coordinator.typography = typography
            coordinator.ink = ink
            coordinator.applyingText = false
        }
        if view.text == text { coordinator.modelText = text }
        if focused && editable && !view.isFirstResponder && view.window != nil { view.becomeFirstResponder() }
        else if (!focused || !editable) && view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UITextView,context:Context)->CGSize? {
        guard let width=proposal.width,width.isFinite,width>0 else { return nil }
        return CGSize(width: width, height: viewportHeight)
    }
    final class Coordinator:NSObject,UITextViewDelegate {
        var parent:JournalTextView
        var typography=""
        var ink:UIColor?
        var modelText: String?
        var applyingText = false
        init(_ parent: JournalTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            guard !applyingText, let value = textView.text, parent.text != value else { return }
            modelText = parent.text
            parent.text = value
            if parent.text == value { modelText = value }
        }
        func textViewDidBeginEditing(_ textView:UITextView) { updateFocus(textView) }
        func textViewDidEndEditing(_ textView:UITextView) { updateFocus(textView) }
        private func updateFocus(_ view:UITextView) {
            Task { @MainActor [weak self,weak view] in
                guard let self,let view else { return }
                let active=view.isFirstResponder
                if self.parent.focused != active { self.parent.focused=active }
            }
        }
    }
}
