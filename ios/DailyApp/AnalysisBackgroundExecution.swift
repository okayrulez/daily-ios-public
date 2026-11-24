import UIKit

@MainActor
final class AnalysisBackgroundExecution {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func start(onExpiration: @escaping () -> Void) {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "dAIly analysis") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.task != .invalid else { return }
                self.finish()
                onExpiration()
            }
        }
    }

    func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
