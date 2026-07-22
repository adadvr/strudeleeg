// ValidateEvents — F1 timing verification
// Prints the events for the first 16 seconds of the seed code and validates
// that pad fires at t=0 and t=8, and bell fires c4@0, e4@4, g4@8, b4@12.
//
// Run with:   swift run ValidateEvents   (or execute the binary directly)

import Foundation
import NativeEngine

// ---------------------------------------------------------------------------
// Seed code (identical to ContentView)
// ---------------------------------------------------------------------------
let seedCode = """
stack(
  s("pad").slow(4).gain(0.5).room(0.6),
  note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
)
"""

let CYCLE_SECONDS = 2.0   // 1 cycle = 2 s (Strudel default)

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------
let parser = MiniNotationParser()
let layers: [Layer]
do {
    layers = try parser.parse(seedCode)
} catch {
    print("PARSE ERROR: \(error)")
    exit(1)
}

print("Parsed \(layers.count) layer(s)\n")
for (i, layer) in layers.enumerated() {
    print("  Layer \(i): sample=\(layer.sample)  slowFactor=\(layer.slowFactor)  isAlternation=\(layer.isAlternation)  baseEvents=\(layer.events.count)  alts=\(layer.alternatives.count)")
    if layer.isAlternation {
        for (ai, alt) in layer.alternatives.enumerated() {
            for ev in alt {
                let noteStr = ev.midiNote.map { "\($0)" } ?? "—"
                print("    alt[\(ai)]: onset=\(ev.cycleOnset)  midi=\(noteStr)")
            }
        }
    } else {
        for ev in layer.events {
            let noteStr = ev.midiNote.map { "\($0)" } ?? "—"
            print("    event: onset=\(ev.cycleOnset)  midi=\(noteStr)")
        }
    }
}
print()

// ---------------------------------------------------------------------------
// Generate events for 0..16 seconds
// ---------------------------------------------------------------------------

struct AbsoluteEvent {
    let layer: Int
    let sample: String
    let midiNote: Int?
    let noteName: String
    let absoluteTime: Double
    let gain: Double?
    let room: Double?
    let cutoff: Double?
}

var allEvents: [AbsoluteEvent] = []
let totalSeconds = 16.0

for (layerIndex, layer) in layers.enumerated() {
    let cycleDuration = CYCLE_SECONDS * layer.slowFactor
    let numCycles = Int(ceil(totalSeconds / cycleDuration)) + 1

    for cycleIndex in 0..<numCycles {
        let cycleStartSec = Double(cycleIndex) * cycleDuration
        let events = layer.eventsForCycle(cycleIndex)
        for event in events {
            let absTime = cycleStartSec + event.cycleOnset * cycleDuration
            guard absTime < totalSeconds else { continue }

            let noteName: String
            if let midi = event.midiNote {
                noteName = midiToName(midi)
            } else {
                noteName = "—"
            }
            allEvents.append(AbsoluteEvent(
                layer: layerIndex,
                sample: layer.sample,
                midiNote: event.midiNote,
                noteName: noteName,
                absoluteTime: absTime,
                gain: layer.gain,
                room: layer.room,
                cutoff: layer.cutoff
            ))
        }
    }
}

// Sort by time
allEvents.sort { $0.absoluteTime < $1.absoluteTime }

// ---------------------------------------------------------------------------
// Print table (pure string interpolation — avoids %s crash on macOS)
// ---------------------------------------------------------------------------

func col(_ s: String, _ width: Int) -> String {
    s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0)
}

let header = col("t(s)", 8) + "  " + col("layer", 6) + "  " + col("sample", 6) + "  " +
             col("note", 5) + "  " + col("gain", 6) + "  " + col("room", 6) + "  " + col("cutoff", 8)
print(header)
print(String(repeating: "-", count: header.count))

for ev in allEvents {
    let t     = String(format: "%.3f", ev.absoluteTime)
    let midi  = ev.midiNote.map { "(\($0))" } ?? ""
    let note  = ev.noteName + (midi.isEmpty ? "" : " \(midi)")
    let gain  = ev.gain.map  { String(format: "%.1f", $0) } ?? "—"
    let room  = ev.room.map  { String(format: "%.1f", $0) } ?? "—"
    let cut   = ev.cutoff.map { String(format: "%.0f", $0) } ?? "—"
    print(col(t, 8) + "  " + col("\(ev.layer)", 6) + "  " +
          col(ev.sample, 6) + "  " + col(note, 14) + "  " +
          col(gain, 6) + "  " + col(room, 6) + "  " + col(cut, 8))
}

// ---------------------------------------------------------------------------
// Validate expected pattern
// ---------------------------------------------------------------------------

print("\n--- Validation ---")
var ok = true

// Pad: slow(4) → cycleDuration = 8s. Fires at 0, 8s in first 16s.
let padEvents = allEvents.filter { $0.sample == "pad" }
let padTimes  = padEvents.map { $0.absoluteTime }
for expected in [0.0, 8.0] {
    let found = padTimes.contains { abs($0 - expected) < 0.001 }
    print("pad @ t=\(expected)s : \(found ? "OK" : "FAIL")")
    if !found { ok = false }
}

// Bell: slow(2) → cycleDuration = 4s, alternation <c4 e4 g4 b4>
// cycle 0 → c4 @ t=0, cycle 1 → e4 @ t=4, cycle 2 → g4 @ t=8, cycle 3 → b4 @ t=12
let bellEvents = allEvents.filter { $0.sample == "bell" }
let expectedBell: [(t: Double, note: String)] = [
    (0.0, "c4"), (4.0, "e4"), (8.0, "g4"), (12.0, "b4")
]
for exp in expectedBell {
    let found = bellEvents.contains { abs($0.absoluteTime - exp.t) < 0.001 && $0.noteName == exp.note }
    print("bell \(exp.note) @ t=\(exp.t)s : \(found ? "OK" : "FAIL")")
    if !found { ok = false }
}

// Validate effects are parsed correctly on layer 0 (pad)
if let padLayer = layers.first(where: { $0.sample == "pad" }) {
    let gainOK = padLayer.gain   == 0.5;  print("pad  gain=0.5 : \(gainOK ? "OK" : "FAIL")"); if !gainOK { ok = false }
    let roomOK = padLayer.room   == 0.6;  print("pad  room=0.6 : \(roomOK ? "OK" : "FAIL")"); if !roomOK { ok = false }
}
// Bell layer effects
if let bellLayer = layers.first(where: { $0.sample == "bell" }) {
    let gainOK   = bellLayer.gain   == 0.7;  print("bell gain=0.7    : \(gainOK   ? "OK" : "FAIL")"); if !gainOK   { ok = false }
    let roomOK   = bellLayer.room   == 0.4;  print("bell room=0.4    : \(roomOK   ? "OK" : "FAIL")"); if !roomOK   { ok = false }
    let cutoffOK = bellLayer.cutoff == 1500;  print("bell cutoff=1500 : \(cutoffOK ? "OK" : "FAIL")"); if !cutoffOK { ok = false }
}

print("\nResult: \(ok ? "ALL PASS ✓" : "SOME CHECKS FAILED ✗")")
exit(ok ? 0 : 1)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func midiToName(_ midi: Int) -> String {
    let names = ["c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b"]
    let octave = (midi / 12) - 1
    let name = names[midi % 12]
    return "\(name)\(octave)"
}
