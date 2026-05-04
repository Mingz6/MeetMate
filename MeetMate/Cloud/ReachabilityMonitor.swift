import Foundation
import Network
import Combine

/// Monitors network reachability and tracks consecutive LLM failures.
///
/// When `consecutiveFailures >= failureThreshold`, sets `isCloudAvailable = false`
/// (triggers "recording only" mode in the UI). Resets on next successful call
/// or when network path transitions to satisfied.
@MainActor
final class ReachabilityMonitor: ObservableObject {
    @Published private(set) var isNetworkAvailable = true
    @Published private(set) var isCloudAvailable = true
    @Published private(set) var consecutiveFailures = 0

    /// After this many consecutive cloud failures, flip to offline mode.
    let failureThreshold = 3

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.mingz.MeetMate.Reachability")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = satisfied

                // Network came back — reset failure count and try cloud again
                if !wasAvailable && satisfied {
                    self.consecutiveFailures = 0
                    self.isCloudAvailable = true
                    print("[Reachability] network restored, resetting cloud availability")
                }

                // Network gone — immediately mark cloud unavailable
                if !satisfied {
                    self.isCloudAvailable = false
                    print("[Reachability] network lost")
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Call after a successful cloud LLM response.
    func reportSuccess() {
        consecutiveFailures = 0
        if !isCloudAvailable {
            isCloudAvailable = true
            print("[Reachability] cloud restored after success")
        }
    }

    /// Call after a failed cloud LLM request (timeout, 5xx, network error).
    func reportFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold && isCloudAvailable {
            isCloudAvailable = false
            print("[Reachability] cloud marked unavailable after \(consecutiveFailures) failures")
        }
    }

    /// Manual toggle — user can pause cloud calls for cost control.
    func pauseCloud() {
        isCloudAvailable = false
        print("[Reachability] cloud paused by user")
    }

    /// Resume cloud after manual pause.
    func resumeCloud() {
        guard isNetworkAvailable else { return }
        consecutiveFailures = 0
        isCloudAvailable = true
        print("[Reachability] cloud resumed by user")
    }
}
