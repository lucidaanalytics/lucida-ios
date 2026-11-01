import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Lifecycle via NotificationCenter (UIApplication on iOS, NSApplication on macOS); no swizzling.
public final class NotificationLifecycleSource: LifecycleSource {
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) {
        #if canImport(UIKit)
        let fg = UIApplication.didBecomeActiveNotification
        let bg = UIApplication.didEnterBackgroundNotification
        #elseif canImport(AppKit)
        let fg = NSApplication.didBecomeActiveNotification
        let bg = NSApplication.didResignActiveNotification
        #else
        return
        #endif
        #if canImport(UIKit) || canImport(AppKit)
        let nc = NotificationCenter.default
        tokens = [
            nc.addObserver(forName: fg, object: nil, queue: nil) { _ in onForeground() },
            nc.addObserver(forName: bg, object: nil, queue: nil) { _ in onBackground() },
        ]
        #endif
    }

    public func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }
}
