import XCTest
import AVFoundation
@testable import MiniEngine

final class LiveEngineTests: XCTestCase {

    // 1) ¿Qué notas produce el parser para la melodía del usuario (ciclo 2)?
    func testMelodyLayerHaps() throws {
        let code = #"note("<~!2 [e5 d#5 e5 d#5 e5 b4 d5 c5 a4 ~ ~ c4 e4 a4 b4 ~] [e4 ~ ~ g#4 b4 c5 ~ ~ e4 ~ e5 d#5 e5 d#5 e5 b4] [d5 c5 a4 ~ ~ c4 e4 a4 b4 ~ e4 ~ c5 b4 a4 ~]!1>").sound("triangle")"#
        let pattern = try CodeParser().parse(code)
        let haps = pattern.query(TimeSpan(Rational(2), Rational(3)))
            .sorted { $0.part.begin < $1.part.begin }
        print("=== MELODY HAPS ciclo 2: \(haps.count) eventos")
        for h in haps.prefix(8) {
            print("  t=\(h.part.begin) note=\(String(describing: h.value["note"])) synth=\(String(describing: h.value["s"])) ")
        }
        XCTAssertGreaterThan(haps.count, 5)
    }

    // Regresión del bug de pitch: el sourceNode sin formato explícito renderizaba
    // al rate del hardware (48k) mientras las voces asumían 44.1k -> e5 salía a
    // 606 Hz (~1.4 semitonos grave). Tap real en mainMixer + cruces por cero.
    func testLiveEngineFrequency() throws {
        let engine = MiniEngine(sampleURLs: [:])
        var captured: [Float] = []
        let lock = NSLock()

        engine.play(code: #"note("e5").sound("sine").gain(0.8)"#)
        // Tap después de play (el engine ya arrancó)
        let av = engine.audioEngineForTesting
        let fmt = av.mainMixerNode.outputFormat(forBus: 0)
        av.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
            lock.lock(); defer { lock.unlock() }
            if let ch = buf.floatChannelData?[0] {
                captured.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.0))
        av.mainMixerNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock(); let samples = captured; lock.unlock()
        print("=== capturados \(samples.count) samples, RMS=\(sqrt(samples.map{$0*$0}.reduce(0,+)/Float(max(1,samples.count))))")
        guard samples.count > 8192 else { XCTFail("sin audio capturado"); return }

        // FFT simple por autocorrelación de cruces por cero en la ventana final
        let sr = fmt.sampleRate
        let win = Array(samples.suffix(16384))
        var crossings = 0
        for i in 1..<win.count where win[i-1] < 0 && win[i] >= 0 { crossings += 1 }
        let freq = Double(crossings) * sr / Double(win.count)
        print("=== frecuencia estimada (cruces por cero): \(freq) Hz (esperado ~659.3)")
        XCTAssertEqual(freq, 659.3, accuracy: 40, "el motor real no está tocando e5")
    }
}
