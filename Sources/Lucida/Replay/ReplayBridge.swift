import Foundation

/// Bridge for hosts that own session, consent and transport themselves (the React Native SDK): one wireframe
/// capture as the JSON `{"width","height","events":[meta, fullSnapshot]}` the JS side ships to POST /v1/replay.
/// Uses the same `RRWebWireframe` encoder as `ReplayRecorder`, so masking is identical (inputs and sensitive
/// views never carry text; other text is starred unless `maskText` is false).
public enum ReplayBridge {
    /// `source` defaults to the UIKit key window; returns nil when no hierarchy is available.
    public static func capture(screen: String, maskText: Bool = true, maskAllTextInputs: Bool = true, maskAllImages: Bool = true,
                               maskSandboxedViews: Bool = true, source: ViewHierarchySource? = nil, at ms: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String? {
        #if canImport(UIKit)
        let src = source ?? UIKitViewHierarchy(captureInputText: !maskAllTextInputs, maskSandboxedViews: maskSandboxedViews)
        #else
        guard let src = source else { return nil }
        #endif
        guard let snap = src.snapshot(screen: screen) else { return nil }
        let body: JSONValue = .object([
            "width": .number(snap.width), "height": .number(snap.height),
            "events": .array([RRWebWireframe.meta(snap, at: ms), RRWebWireframe.fullSnapshot(snap, maskText: maskText, maskInputs: maskAllTextInputs, maskImages: maskAllImages, at: ms)]),
        ])
        return (try? JSONEncoder().encode(body)).map { String(decoding: $0, as: UTF8.self) }
    }
}
