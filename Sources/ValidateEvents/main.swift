// ValidateEvents — timing verification using MiniEngine (Phase 0)
//
// Parses the seed code with the new Pattern-based engine, queries events for
// 0..16 seconds, and validates the expected timing + effects.
//
// Run with:  swift run ValidateEvents

import Foundation
import MiniEngine

// ---------------------------------------------------------------------------
// Seed code (identical to ContentView)
// ---------------------------------------------------------------------------
let seedCode = """
stack(
  s("pad").slow(4).gain(0.5).room(0.6),
  note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
)
"""

let CYCLE_SECONDS = 2.0   // 0.5 cps → 1 cycle = 2 s

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------
let parser = CodeParser()
let pattern: ControlPattern
do {
    pattern = try parser.parse(seedCode)
} catch {
    print("PARSE ERROR: \(error)")
    exit(1)
}

// ---------------------------------------------------------------------------
// Query events for 0..totalSeconds
// ---------------------------------------------------------------------------
let totalSeconds = 16.0
let totalCycles  = Rational(approximating: totalSeconds / CYCLE_SECONDS)  // 8 cycles

let haps = pattern.queryArc(Rational(0), totalCycles)
print("Total haps in [0, \(totalCycles)) cycles (\(Int(totalSeconds))s): \(haps.count)\n")

// Convert hap to an absolute event
struct AbsoluteEvent {
    let sample:   String
    let midiNote: Int?
    let noteName: String
    let absTime:  Double
    let gain:     Double?
    let room:     Double?
    let cutoff:   Double?
}

var allEvents: [AbsoluteEvent] = []

for hap in haps {
    guard let sampleName = hap.value["s"]?.stringValue else { continue }

    // Use part.begin as onset (cycle units)
    let onsetCycles = hap.part.begin.toDouble
    let absTime     = onsetCycles * CYCLE_SECONDS

    guard absTime < totalSeconds else { continue }

    let midiNote  = hap.value["note"]?.doubleValue.map { Int($0) } ?? nil
    let noteName  = midiNote.map { midiToNoteName($0) } ?? "—"

    allEvents.append(AbsoluteEvent(
        sample:   sampleName,
        midiNote: midiNote,
        noteName: noteName,
        absTime:  absTime,
        gain:     hap.value["gain"]?.doubleValue,
        room:     hap.value["room"]?.doubleValue,
        cutoff:   hap.value["cutoff"]?.doubleValue
    ))
}

// Deduplicate by (sample, absTime, midiNote) — withControl produces one hap
// per cycle but the scheduler only fires on the onset, so each event is unique.
// Actually keep all events; scheduler deduplicates via time window.
allEvents.sort { $0.absTime < $1.absTime }

// ---------------------------------------------------------------------------
// Print table
// ---------------------------------------------------------------------------

func col(_ s: String, _ w: Int) -> String {
    s.padding(toLength: max(s.count, w), withPad: " ", startingAt: 0)
}

let header = col("t(s)", 8) + "  " + col("sample", 6) + "  " +
             col("note", 14) + "  " + col("gain", 6) + "  " +
             col("room", 6) + "  " + col("cutoff", 8)
print(header)
print(String(repeating: "-", count: header.count))

// Print only the *first* event per (sample, onset, note) combination
var printed: Set<String> = []
for ev in allEvents {
    let key = "\(ev.sample)_\(ev.absTime)_\(ev.midiNote ?? -1)"
    guard !printed.contains(key) else { continue }
    printed.insert(key)

    let t      = String(format: "%.3f", ev.absTime)
    let note   = ev.noteName + (ev.midiNote.map { " (\($0))" } ?? "")
    let gain   = ev.gain.map  { String(format: "%.2f", $0) } ?? "—"
    let room   = ev.room.map  { String(format: "%.2f", $0) } ?? "—"
    let cut    = ev.cutoff.map { String(format: "%.0f", $0) } ?? "—"
    print(col(t, 8) + "  " + col(ev.sample, 6) + "  " +
          col(note, 14) + "  " + col(gain, 6) + "  " + col(room, 6) + "  " + col(cut, 8))
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

print("\n--- Validation ---")
var ok = true

// Helper: find a unique event at approximate time t for a given sample
func hasEvent(sample: String, approxTime t: Double, noteName: String? = nil) -> Bool {
    printed.contains("\(sample)_\(String(format: "%.3f", t))_\(-1)") ||
    allEvents.contains {
        $0.sample == sample &&
        abs($0.absTime - t) < 0.001 &&
        (noteName == nil || $0.noteName == noteName)
    }
}

// Pad: slow(4) → period = 8s. Fires at t=0 and t=8 in first 16s.
for t in [0.0, 8.0] {
    let found = allEvents.contains { $0.sample == "pad" && abs($0.absTime - t) < 0.001 }
    print("pad @ t=\(t)s : \(found ? "OK" : "FAIL")")
    if !found { ok = false }
}

// Bell: slow(2) → period=4s, alternation <c4 e4 g4 b4>
// cycle 0 → c4 @ t=0, cycle 1 → e4 @ t=4, cycle 2 → g4 @ t=8, cycle 3 → b4 @ t=12
let bellCases: [(t: Double, note: String)] = [
    (0.0, "c4"), (4.0, "e4"), (8.0, "g4"), (12.0, "b4")
]
for exp in bellCases {
    let found = allEvents.contains {
        $0.sample == "bell" &&
        abs($0.absTime - exp.t) < 0.001 &&
        $0.noteName == exp.note
    }
    print("bell \(exp.note) @ t=\(exp.t)s : \(found ? "OK" : "FAIL")")
    if !found { ok = false }
}

// Effect validation: find a pad event and check its effects
if let padEv = allEvents.first(where: { $0.sample == "pad" }) {
    let gainOK = padEv.gain.map { abs($0 - 0.5) < 0.001 } ?? false
    let roomOK = padEv.room.map { abs($0 - 0.6) < 0.001 } ?? false
    let noCutoffOK = padEv.cutoff == nil
    print("pad  gain=0.5 : \(gainOK ? "OK" : "FAIL")"); if !gainOK { ok = false }
    print("pad  room=0.6 : \(roomOK ? "OK" : "FAIL")"); if !roomOK { ok = false }
    print("pad  cutoff=nil : \(noCutoffOK ? "OK" : "FAIL")"); if !noCutoffOK { ok = false }
}

if let bellEv = allEvents.first(where: { $0.sample == "bell" }) {
    let gainOK   = bellEv.gain.map   { abs($0 - 0.7) < 0.001 } ?? false
    let roomOK   = bellEv.room.map   { abs($0 - 0.4) < 0.001 } ?? false
    let cutoffOK = bellEv.cutoff.map { abs($0 - 1500) < 0.1  } ?? false
    print("bell gain=0.7 : \(gainOK   ? "OK" : "FAIL")"); if !gainOK   { ok = false }
    print("bell room=0.4 : \(roomOK   ? "OK" : "FAIL")"); if !roomOK   { ok = false }
    print("bell cutoff=1500 : \(cutoffOK ? "OK" : "FAIL")"); if !cutoffOK { ok = false }
}

print("\nResult: \(ok ? "ALL PASS ✓" : "SOME CHECKS FAILED ✗")")
exit(ok ? 0 : 1)

// midiToNoteName is a public free function in MiniEngine module (MiniNotationCore.swift)
// — no local wrapper needed; imported directly via `import MiniEngine`.
