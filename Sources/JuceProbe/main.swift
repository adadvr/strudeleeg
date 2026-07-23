import Foundation
import AVFoundation
import StrudelJuceC

// ---------------------------------------------------------------------------
// JuceProbe — verificación headless de la Fase 0 del motor JUCE.
// Crea el motor, abre el device de audio, reproduce el test tone ~0.8s y
// confirma isRunning. Sirve de smoke test del enlace C API + CoreAudio.
//   swift run JuceProbe            (440 Hz)
//   swift run JuceProbe 660        (freq custom)
// Exit 0 = engine corrió; != 0 = no abrió el device.
// ---------------------------------------------------------------------------

let freq: Float = CommandLine.arguments.count > 1 ? (Float(CommandLine.arguments[1]) ?? 440) : 440

print("[JuceProbe] creando motor JUCE…")
let engine = strudel_engine_create()
defer { strudel_engine_destroy(engine) }

let rc = strudel_engine_start(engine)
let running = strudel_engine_is_running(engine) != 0
print("[JuceProbe] start rc=\(rc), isRunning=\(running)")

guard running else {
    FileHandle.standardError.write("[JuceProbe] ERROR: el device de audio no abrió\n".data(using: .utf8)!)
    exit(1)
}

let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tone"

if mode == "synth" {
    // Fase 2: agenda una secuencia de sawtooth con LPF para probar las voces.
    print("[JuceProbe] synths: sawtooth c-e-g con lpf 1200, 1.2s…")
    let notes: [(Double, Double)] = [(0.0, 261.63), (0.3, 329.63), (0.6, 392.0)]  // c4 e4 g4
    for (delay, f) in notes {
        strudel_engine_schedule_synth(
            engine, delay, "sawtooth",
            f, 0.8,            // freq, gain
            0.01, 0.1, 0.7, 0.2,  // adsr
            0.25,              // durationSec
            1200, -1, -1,      // lpf, hpf, resonance
            -1, 0, 0, 0, 1.0, 1)  // pan, crush, lpenv, hpenv, postgain
    }
    Thread.sleep(forTimeInterval: 1.2)
    strudel_engine_all_notes_off(engine)
} else if mode == "sample" {
    // Fase 3: carga un WAV generado (sine burst) y lo agenda 3 veces.
    let sr = 44100.0, n = Int(sr * 0.4)
    var pcm = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let env = Float(1.0 - Double(i) / Double(n))
        pcm[i] = 0.6 * sinf(2.0 * .pi * 220.0 * Float(i) / Float(sr)) * env
    }
    pcm.withUnsafeBufferPointer { bp in
        strudel_engine_load_sample(engine, "probe", bp.baseAddress, nil, 1, Int64(n), sr)
    }
    print("[JuceProbe] has 'probe' = \(strudel_engine_has_sample(engine, "probe"))")
    print("[JuceProbe] sample: 3 hits con lpf 800, 1.2s…")
    for (i, delay) in [0.0, 0.4, 0.8].enumerated() {
        let ratio = pow(2.0, Double(i * 3) / 12.0)  // repitch escalonado
        strudel_engine_schedule_sample(
            engine, delay, "probe",
            ratio, 0.8, 1.0,      // ratio, gain, postgain
            -1, -1,               // begin, end
            800, -1, -1,          // lpf, hpf, res
            -1, 0,                // pan, crush
            0, 0.01, 0.1, 0.8, 0.1, 0.4, 1)  // hasADSR, adsr, dur
    }
    Thread.sleep(forTimeInterval: 1.2)
    strudel_engine_all_notes_off(engine)
} else {
    print("[JuceProbe] test tone \(freq) Hz por 0.8s…")
    strudel_engine_set_test_tone(engine, 1, freq)
    Thread.sleep(forTimeInterval: 0.8)
    strudel_engine_set_test_tone(engine, 0, freq)
}

strudel_engine_stop(engine)
print("[JuceProbe] OK ✅ (device abierto, audio reproducido, engine parado)")
exit(0)
