import Foundation

/// Converts a wireframe into rrweb events (the format `POST /v1/replay` and lc-replay accept):
/// Meta (type 4), FullSnapshot (type 2, DOM-like tree of absolutely positioned divs) and the
/// custom `navigation` event (type 5) that lc-replay reads as a URL change (`app://<screen>`).
/// Text is masked by default: every non-space character becomes `*`, so layout survives but content does not.
enum RRWebWireframe {
    static func mask(_ s: String) -> String { String(s.map { $0.isWhitespace ? $0 : "*" }) }

    static func meta(_ s: WireframeSnapshot, at ms: Int64) -> JSONValue {
        event(4, ms, ["href": .string("app://\(s.screen)"), "width": .number(s.width), "height": .number(s.height)])
    }

    static func navigation(_ s: WireframeSnapshot, at ms: Int64) -> JSONValue {
        event(5, ms, ["tag": "navigation", "payload": ["url": .string("app://\(s.screen)")]])
    }

    static func fullSnapshot(_ s: WireframeSnapshot, maskText: Bool, maskInputs: Bool = true, maskImages: Bool = true, at ms: Int64) -> JSONValue {
        var nextId = 3  // 1 = document, 2 = html
        func build(_ n: WireframeNode, isRoot: Bool) -> JSONValue {
            let id = nextId; nextId += 1
            var style = "position:\(isRoot ? "relative" : "absolute");left:\(fmt(n.x))px;top:\(fmt(n.y))px;width:\(fmt(n.width))px;height:\(fmt(n.height))px;overflow:hidden"
            if let b = n.background { style += ";background-color:\(b)" }
            var kids = n.children.map { build($0, isRoot: false) }
            // Sensitive views never carry text; inputs only when the app turned input masking off or unmasked the node.
            if let t = n.text, !t.isEmpty, !n.sensitive {
                let masked = n.kind == .input ? (maskInputs && !n.unmask) : (maskText && !n.unmask)
                let tid = nextId; nextId += 1
                kids.insert(.object(["type": 3, "id": .number(Double(tid)), "textContent": .string(masked ? mask(t) : t)]), at: 0)
            }
            var attrs: Props = ["class": .string("lc-wf lc-wf-\(n.kind.rawValue)"), "style": .string(style), "data-lc-view": .string(n.kind.rawValue)]
            if n.kind == .image, maskImages, !n.unmask { attrs["data-lc-mask"] = .string("") }
            return .object([
                "type": 2, "id": .number(Double(id)), "tagName": .string(isRoot ? "body" : "div"),
                "attributes": .object(attrs),
                "childNodes": .array(kids),
            ])
        }
        let body = build(s.root, isRoot: true)
        let html: JSONValue = .object(["type": 2, "id": 2, "tagName": "html", "attributes": [:], "childNodes": .array([body])])
        let doc: JSONValue = .object(["type": 0, "id": 1, "childNodes": .array([html])])
        return event(2, ms, ["node": doc, "initialOffset": ["left": 0, "top": 0]])
    }

    /// Screenshot mode: a FullSnapshot whose body holds one `<img>` (data: JPEG, already masked on device). The
    /// rrweb player renders it as-is; ids: body 3, img 4.
    static func screenshotSnapshot(_ s: WireframeSnapshot, jpeg: Data, at ms: Int64) -> JSONValue {
        let img: JSONValue = .object([
            "type": 2, "id": 4, "tagName": "img",
            "attributes": .object(["src": .string("data:image/jpeg;base64," + jpeg.base64EncodedString()),
                                   "style": .string("width:\(fmt(s.width))px;height:\(fmt(s.height))px"), "data-lc-view": "screenshot"]),
            "childNodes": [],
        ])
        let body: JSONValue = .object(["type": 2, "id": 3, "tagName": "body", "attributes": ["class": "lc-wf lc-wf-screenshot"], "childNodes": .array([img])])
        let html: JSONValue = .object(["type": 2, "id": 2, "tagName": "html", "attributes": [:], "childNodes": .array([body])])
        let doc: JSONValue = .object(["type": 0, "id": 1, "childNodes": .array([html])])
        return event(2, ms, ["node": doc, "initialOffset": ["left": 0, "top": 0]])
    }

    /// Id `fullSnapshot` gives the deepest node containing the window point (same numbering), else the root.
    static func nodeAt(_ s: WireframeSnapshot, x: Double, y: Double) -> Int {
        var nextId = 3, hit = 3
        func walk(_ n: WireframeNode, ox: Double, oy: Double, isRoot: Bool) {
            let id = nextId; nextId += 1
            let left = isRoot ? 0 : ox + n.x, top = isRoot ? 0 : oy + n.y
            if x >= left, x < left + n.width, y >= top, y < top + n.height { hit = id }
            for c in n.children { walk(c, ox: left, oy: top, isRoot: false) }
            if let t = n.text, !t.isEmpty, !n.sensitive { nextId += 1 }  // text id follows the children
        }
        walk(s.root, ox: 0, oy: 0, isRoot: true)
        return hit
    }

    /// A tap as an rrweb MouseInteraction Click (type 3, source 2, interaction 2), like the Android SDK.
    static func tap(_ s: WireframeSnapshot, x: Double, y: Double, at ms: Int64) -> JSONValue {
        event(3, ms, ["source": 2, "type": 2, "id": .number(Double(nodeAt(s, x: x, y: y))), "x": .number(x), "y": .number(y)])
    }

    /// A scroll / swipe gesture as an rrweb TouchMove (type 3, source 6): the finger path, offsets from `ms`.
    static func swipe(_ s: WireframeSnapshot, path: [TouchPoint], at ms: Int64) -> JSONValue {
        let id = Double(nodeAt(s, x: path.first?.x ?? 0, y: path.first?.y ?? 0))
        let pos: [JSONValue] = path.map { .object(["x": .number($0.x), "y": .number($0.y), "id": .number(id), "timeOffset": .number(Double($0.offsetMs))]) }
        return event(3, ms, ["source": 6, "positions": .array(pos)])
    }

    private static func event(_ type: Int, _ ms: Int64, _ data: Props) -> JSONValue {
        .object(["type": .number(Double(type)), "timestamp": .number(Double(ms)), "data": .object(data)])
    }

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}
