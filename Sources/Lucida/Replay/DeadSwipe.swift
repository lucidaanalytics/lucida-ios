import Foundation

/// P-M46 `$dead_swipe`: a swipe of at least 48 pt after which nothing on screen scrolled, paged or changed (the
/// structure fingerprint ~700 ms after the gesture equals the one at its start). Carries geometry only, never text.
enum DeadSwipe {
    static let minDistance = 48.0
    static let settleSeconds = 0.7
    static let cooldownMs: Int64 = 2000

    /// Dominant axis of end - start; screen y grows downwards.
    static func direction(dx: Double, dy: Double) -> String {
        abs(dx) >= abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
    }

    /// The `$dead_swipe` properties when the swipe was dead and the 2 s cooldown has passed, else nil.
    static func decide(screen: String, startScreen: String, startFingerprint: String, endFingerprint: String,
                       dx: Double, dy: Double, nowMs: Int64, lastAt: Int64?) -> Props? {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= minDistance, screen == startScreen, startFingerprint == endFingerprint,
              lastAt.map({ nowMs - $0 >= cooldownMs }) ?? true else { return nil }
        return [
            "$screen_name": .string(screen), "$swipe_direction": .string(direction(dx: dx, dy: dy)),
            "$swipe_distance": .number(distance.rounded()),
        ]
    }
}
