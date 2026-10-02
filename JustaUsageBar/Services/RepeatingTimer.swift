import Foundation

/// A UI timer whose lifetime is bounded by its owner.
@MainActor
final class RepeatingTimer {
    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard self != nil else {
                    timer.invalidate()
                    return
                }
                action()
            }
        }
        timer?.tolerance = interval * 0.1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
