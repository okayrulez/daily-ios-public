import SwiftUI
import UIKit

/// A non-cancelling tap dismisses editing outside text inputs. Scrolling retains
/// UIKit's interactive keyboard transition; tapping the editor never blurs it.
struct BackgroundKeyboardDismissal: UIViewRepresentable {
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.onDismiss = onDismiss
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: Anchor, context: Context) { uiView.onDismiss = onDismiss }
    static func dismantleUIView(_ uiView: Anchor, coordinator: ()) { uiView.detach() }

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void = {}
        private var tap: UITapGestureRecognizer?
        private var pan: UIPanGestureRecognizer?
        private var dismissedDuringPan = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            tap = recognizer
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
            scroll.cancelsTouchesInView = false
            scroll.delegate = self
            window.addGestureRecognizer(scroll)
            pan = scroll
        }
        func detach() {
            if let tap { tap.view?.removeGestureRecognizer(tap) }
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            tap = nil
            pan = nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window, !isHidden, bounds.width > 0,
                  convert(bounds, to: window).contains(touch.location(in: window)) else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 { return false }
                ancestor = view.superview
            }
            var candidate = touch.view
            while let view = candidate {
                if let input = view as? UITextInput {
                    // Preserve input taps and selected-text handle drags.
                    if gestureRecognizer === tap { return false }
                    if let range = input.selectedTextRange, !range.isEmpty { return false }
                }
                candidate = view.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { dismissedDuringPan = false }
            let movement = recognizer.translation(in: window)
            // Native interactive dismissal follows a downward drag. Upward
            // scrolling also closes editing, using the native keyboard animation.
            guard recognizer.state == .changed, !dismissedDuringPan,
                  movement.y < -22, abs(movement.y) > abs(movement.x) else { return }
            dismissedDuringPan = true
            tapped()
        }
        @objc private func tapped() {
            window?.endEditing(true)
            onDismiss()
        }
    }
}
