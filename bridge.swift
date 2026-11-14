// Neon Hive native bridge: browser -> ws://127.0.0.1:8765 -> GameController + Core Haptics on the DualSense.
// Run: swift bridge.swift   (or: swiftc -O bridge.swift -o neon-bridge && ./neon-bridge)
//
// Messages (JSON, one per WebSocket frame):
//   {"h": [[time, duration(0 = transient), intensity, sharpness, pan -1..1], ...]}   haptic pattern
//   {"r2": mode, "l2": mode, "rgb": [r,g,b] 0..1, "p": 0..4}                          controller state
//   mode = ["off"] | ["fb", start, strength] | ["wp", start, end, strength] | ["vb", start, amp, freq]
//        | ["mf", s0..s9] (strength at each of 10 positions) | ["sl", start, end, startStrength, endStrength]  (all 0..1)
import Foundation
import Network
import GameController
import CoreHaptics

final class Pad {
    var ctrl: GCController?
    var engines: [String: CHHapticEngine] = [:]

    func attach(_ c: GCController) {
        guard let h = c.haptics else { print("ignoring \(c.vendorName ?? "controller"): no haptics"); return }
        ctrl = c
        engines = [:]
        for (k, loc) in [("L", GCHapticsLocality.leftHandle), ("R", .rightHandle)] {
            if let e = h.createEngine(withLocality: loc) { engines[k] = e }
        }
        if engines.isEmpty, let e = h.createEngine(withLocality: .default) { engines["B"] = e } // no per-grip actuators
        for e in engines.values {
            e.resetHandler = { try? e.start() }
            e.stoppedHandler = { _ in try? e.start() }
            try? e.start()
        }
        print("controller: \(c.vendorName ?? "?")  engines: \(engines.keys.sorted())")
    }

    func detach(_ c: GCController) {
        guard c === ctrl else { return }
        ctrl = nil
        engines = [:]
        print("controller disconnected")
    }

    // Each grip gets its own copy of the pattern, with every event scaled by its pan.
    func play(_ ev: [[Double]]) {
        for (k, e) in engines {
            var events: [CHHapticEvent] = []
            var curves: [CHHapticParameterCurve] = []
            for v in ev where v.count >= 4 {
                let (t, d, i, s) = (v[0], v[1], v[2], v[3])
                let pan = v.count > 4 ? v[4] : 0
                let gain = k == "L" ? min(1, 1 - pan) : k == "R" ? min(1, 1 + pan) : 1
                if i * gain < 0.01 { continue }
                let p = [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(i * gain)),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(s))]
                if d > 0 {
                    events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: p, relativeTime: t, duration: d))
                    // shortcut: intensity curves apply to the whole player, so overlapping events in one pattern also fade; give each event its own player if that matters.
                    curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                        controlPoints: [.init(relativeTime: 0, value: 1), .init(relativeTime: d, value: 0)], relativeTime: t))
                } else {
                    events.append(CHHapticEvent(eventType: .hapticTransient, parameters: p, relativeTime: t))
                }
            }
            guard !events.isEmpty else { continue }
            do {
                let player = try e.makePlayer(with: CHHapticPattern(events: events, parameterCurves: curves))
                try player.start(atTime: CHHapticTimeImmediate)
            } catch { print("haptics:", error) }
        }
    }

    func trigger(_ t: GCDualSenseAdaptiveTrigger, _ m: [Any]) {
        let f = m.dropFirst().map { Float(($0 as? Double) ?? 0) }
        switch (m.first as? String, f.count) {
        case ("fb", 2...): t.setModeFeedbackWithStartPosition(f[0], resistiveStrength: f[1])
        case ("wp", 3...): t.setModeWeaponWithStartPosition(f[0], endPosition: f[1], resistiveStrength: f[2])
        case ("vb", 3...): t.setModeVibrationWithStartPosition(f[0], amplitude: f[1], frequency: f[2])
        case ("mf", 10...):
            var s = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            s.values = (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9])
            t.setModeFeedback(resistiveStrengths: s)
        case ("sl", 4...): t.setModeSlopeFeedback(startPosition: f[0], endPosition: f[1], startStrength: f[2], endStrength: f[3])
        default: t.setModeOff()
        }
    }

    func state(_ j: [String: Any]) {
        guard let c = ctrl else { return }
        if let ds = c.extendedGamepad as? GCDualSenseGamepad {
            if let r = j["r2"] as? [Any] { trigger(ds.rightTrigger, r) }
            if let l = j["l2"] as? [Any] { trigger(ds.leftTrigger, l) }
        }
        if let rgb = j["rgb"] as? [Double], rgb.count == 3 {
            c.light?.color = GCColor(red: Float(rgb[0]), green: Float(rgb[1]), blue: Float(rgb[2]))
        }
        if let p = j["p"] as? Int { c.playerIndex = GCControllerPlayerIndex(rawValue: min(p, 4) - 1) ?? .indexUnset }
    }

    var info: Data {
        let o: [String: Any] = ["ctrl": ctrl?.vendorName ?? NSNull(), "engines": engines.keys.sorted()]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer logs even when piped
let pad = Pad()
GCController.shouldMonitorBackgroundEvents = true
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
    if let c = n.object as? GCController { pad.attach(c) }
}
NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
    if let c = n.object as? GCController { pad.detach(c) }
}
GCController.controllers().forEach(pad.attach)

// Loopback only, and only pages served from localhost or opened as files may connect.
let ws = NWProtocolWebSocket.Options()
ws.autoReplyPing = true
ws.setClientRequestHandler(.main) { _, headers in
    let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? "null"
    let ok = origin == "null" || origin.hasPrefix("http://localhost:") || origin.hasPrefix("http://127.0.0.1:")
    if !ok { print("rejected origin \(origin)") }
    return .init(status: ok ? .accept : .reject, subprotocol: nil, additionalHeaders: nil)
}
let params = NWParameters.tcp
params.requiredInterfaceType = .loopback
params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

func send(_ c: NWConnection, _ data: Data) {
    let ctx = NWConnection.ContentContext(identifier: "info", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    c.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
}
func receive(_ c: NWConnection) {
    c.receiveMessage { data, _, _, err in
        if let data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let h = j["h"] as? [[Double]] { pad.play(h) }
            if j["hello"] != nil { send(c, pad.info) } else { pad.state(j) }
        }
        if err == nil { receive(c) } else { c.cancel() }
    }
}

let listener = try NWListener(using: params, on: 8765)
listener.newConnectionHandler = { c in
    c.start(queue: .main)
    receive(c)
}
listener.start(queue: .main)
print("Neon Hive haptics bridge on ws://127.0.0.1:8765 — waiting for a DualSense…")
RunLoop.main.run()
