import SwiftUI
import UIKit

/// Measures the rehearsal's actual UIKit tab bar after layout. No screen-width
/// division, private class names, timers, or inspection of the live workspace.
struct TourNativeTabTarget: UIViewRepresentable {
    let registry: TourSpotlightRegistry
    let label: String

    func makeUIView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateUIView(_ view: Probe, context: Context) {
        view.registry = registry; view.label = label; view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.registry?.remove("active-tab", owner: view.owner)
    }

    final class Probe: UIView {
        weak var registry: TourSpotlightRegistry?
        var label = ""
        let owner = UUID()
        private var scheduled = false
        override init(frame: CGRect) {
            super.init(frame: frame); isUserInteractionEnabled = false; isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !scheduled else { return }
            scheduled = true
            // Publishing during UIViewRepresentable's update would invalidate the
            // SwiftUI layout in progress. Defer only this measurement one turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduled = false; self.capture()
            }
        }
        private func capture() {
            guard window != nil, let bar = enclosingTabBar(), !bar.isHidden, bar.bounds.width > 0 else { return }
            let candidates = descendants(of: bar).filter {
                !$0.isHidden && $0.alpha > 0 && $0.bounds.width > 0 &&
                    $0.accessibilityLabel == label && ($0 is UIControl || $0.accessibilityTraits.contains(.button))
            }
            // Prefer the full native control over an accessibility child label.
            var target = candidates.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            if target == nil, let items = bar.items,
               let index = items.firstIndex(where: { $0.title == label || $0.accessibilityLabel == label }) {
                // Some iOS versions expose the title on the item, rather than its
                // control. Use measured controls only when the one-to-one mapping
                // is unambiguous, including right-to-left layouts.
                let controls = descendants(of: bar).compactMap { $0 as? UIControl }.filter {
                    !$0.isHidden && $0.alpha > 0 && $0.bounds.height >= 20 && $0.bounds.width >= 30
                }.sorted {
                    let left = $0.convert($0.bounds, to: bar).midX
                    let right = $1.convert($1.bounds, to: bar).midX
                    return bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? left > right : left < right
                }
                if controls.count == items.count { target = controls[index] }
            }
            let frame = (target ?? bar).convert((target ?? bar).bounds, to: nil)
            registry?.update(frame, id: "active-tab", owner: owner)
        }
        private func enclosingTabBar() -> UITabBar? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let tabs = controller.tabBarController { return tabs.tabBar }
                if let tabs = current as? UITabBarController { return tabs.tabBar }
                responder = current.next
            }
            return nil
        }
        private func descendants(of view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
    }
}
