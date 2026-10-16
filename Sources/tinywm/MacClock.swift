import Foundation
import QuartzCore
import WindowCore

/// Real time for animations, driven from the main queue.
@MainActor
final class MacClock: Clock {
    var now: Double { CACurrentMediaTime() }

    func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { action() } }
    }
}
