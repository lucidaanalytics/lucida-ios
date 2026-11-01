import Foundation

/// Bridge for hosts that own session, consent and transport themselves (the React Native SDK): one wireframe
/// capture as the JSON `{"width","height","events":[meta, fullSnapshot]}` the JS side ships to POST /v1/replay.
/// Uses the same `RRWebWireframe` encoder as `ReplayRecorder`, so masking is identical (inputs and sensitive
/// views never carry text; other text is starred unless `maskText` is false).
public enum ReplayBridge {
    /// `source` defaults to the UIKit key window; returns nil when no hierarchy is available. With `screenshotQuality`
    /// (0...1) the full snapshot is a JPEG drawn by `screenshots` (default `UIKitScreenshot`) with the same mask plan
    /// `ReplayRecorder` uses, painted before encoding; nil when no frame could be drawn.
    public static func capture(screen: String, maskText: Bool = true, maskAllTextInputs: Bool = true, maskAllImages: Bool = true,
                               maskSandboxedViews: Bool = true, screenshotQuality: Double? = nil, source: ViewHierarchySource? = nil,
                               screenshots: ScreenshotSource? = nil, at ms: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String? {
        #if canImport(UIKit)
        let src = source ?? UIKitViewHierarchy(captureInputText: !maskAllTextInputs, maskSandboxedViews: maskSandboxedViews)
        #else
        guard let src = source else { return nil }
        #endif
        guard let snap = src.snapshot(screen: screen) else { return nil }
        var full = RRWebWireframe.fullSnapshot(snap, maskText: maskText, maskInputs: maskAllTextInputs, maskImages: maskAllImages, at: ms)
        if let quality = screenshotQuality {
            #if canImport(UIKit)
            let shooter = screenshots ?? UIKitScreenshot()
            #else
            guard let shooter = screenshots else { return nil }
            #endif
            let plan = ScreenshotMasks.plan(snap, maskText: maskText, maskInputs: maskAllTextInputs, maskImages: maskAllImages)
            guard let frame = shooter.screenshot(plan: plan, quality: min(1, max(0, quality))) else { return nil }
            full = RRWebWireframe.screenshotSnapshot(snap, jpeg: frame.jpeg, at: ms)
        }
        let body: JSONValue = .object([
            "width": .number(snap.width), "height": .number(snap.height),
            "events": .array([RRWebWireframe.meta(snap, at: ms), full]),
        ])
        return (try? JSONEncoder().encode(body)).map { String(decoding: $0, as: UTF8.self) }
    }
}
