import XCTest
import AVFoundation
@testable import MiniEngine

// MARK: - RMS helper (shared by tests)

private func rmsInWindow(_ samples: [Float], sampleRate: Double, startSec: Double, durationSec: Double) -> Double {
    let startF = Int(startSec * sampleRate)
    let endF   = min(samples.count, startF + Int(durationSec * sampleRate))
    guard startF < endF else { return 0.0 }
    let sum = samples[startF..<endF].reduce(0.0) { $0 + Double($1 * $1) }
    return sqrt(sum / Double(endF - startF))
}

// MARK: - Tests

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

    // ─── Regresión de calibración de volumen (VolumeCalibrate 2026-07-23) ────────
    //
    // Mide el ratio RMS synth(triangle a4 gain 0.5) / sample(bd gain 0.95) en el
    // motor real y verifica que cae dentro del rango calibrado contra Strudel.
    //
    // Valores de referencia medidos con WebProbe --record el 2026-07-23:
    //   RMS_bd_strudel       = 0.213416  (s("bd*4").gain(0.95), 3s, warmup 0.3s)
    //   RMS_triangle_strudel = 0.052425  (note("a4").sound("triangle").gain(0.5))
    //   ratio_strudel        = 0.245647
    //
    // Tolerancia: ±30% del ratio Strudel (≈ ±2.3 dB).
    //   Rango aceptable: [ratio_strudel × 0.70, ratio_strudel × 1.30]
    //                  = [0.1719, 0.3193]
    //
    // El test usa el engine real (AVAudioEngine live) con un tap en mainMixer,
    // siguiendo el mismo patrón que testLiveEngineFrequency.
    // Patrón bd: s("bd*4").gain(0.95) — requiere el archivo bd.wav en sampleURLs.
    // Si no hay bd.wav disponible (sampleURLs vacío), el test se salta.
    func testSynthBdRatioMatchesStrudel() throws {
        // ── Valores de referencia Strudel (WebProbe --record, 2026-07-23) ──
        let strudelRatio: Double = 0.245647   // triangle/bd
        let toleranceLow:  Double = strudelRatio * 0.70   // -30%
        let toleranceHigh: Double = strudelRatio * 1.30   // +30%

        // ── Buscar bd.wav en el bundle de recursos del test ──────────────────
        // LiveEngineTests no tiene acceso a los samples de la app principal,
        // así que buscamos en Fixtures/ o usamos el camino de fuente si existe.
        // Si no encontramos el sample, saltamos el test (no falla, ya que la
        // ausencia de un archivo de audio no es un error del motor en sí).
        var bdURL: URL? = nil
        let candidatePaths = [
            // Fuentes del proyecto (build desde el repo raíz)
            "/Users/adadrosado/Desktop/projects/strudeleeg/Sources/DemoStrudelApp/Samples/bd.wav",
            // Path relativo desde el directorio de trabajo del test runner
            "Sources/DemoStrudelApp/Samples/bd.wav",
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                bdURL = URL(fileURLWithPath: path)
                break
            }
        }

        guard let bdURL = bdURL else {
            print("=== [testSynthBdRatioMatchesStrudel] bd.wav no encontrado — test saltado")
            return  // skip gracefully
        }

        let sampleURLs: [String: URL] = ["bd": bdURL]

        // ── Función auxiliar para capturar RMS del mainMixer ─────────────────
        func captureRMS(code: String, warmupSec: Double = 0.3, durationSec: Double = 3.0) -> Double {
            let engine = MiniEngine(sampleURLs: sampleURLs)
            var captured: [Float] = []
            let lock = NSLock()

            engine.play(code: code)
            Thread.sleep(forTimeInterval: 0.05)   // pequeño delay antes del tap

            let av = engine.audioEngineForTesting
            let fmt = av.mainMixerNode.outputFormat(forBus: 0)
            let sr = fmt.sampleRate

            av.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
                lock.lock(); defer { lock.unlock() }
                if let ch = buf.floatChannelData?[0] {
                    captured.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: warmupSec + durationSec))
            av.mainMixerNode.removeTap(onBus: 0)
            engine.stop()

            lock.lock(); let samples = captured; lock.unlock()
            return rmsInWindow(samples, sampleRate: sr, startSec: warmupSec, durationSec: durationSec)
        }

        // ── Medir bd y triangle ───────────────────────────────────────────────
        let rmsBd       = captureRMS(code: #"s("bd*4").gain(0.95)"#)
        let rmsTri      = captureRMS(code: #"note("a4").sound("triangle").gain(0.5)"#)

        guard rmsBd > 1e-6 else {
            XCTFail("RMS bd es cero — bd.wav no se reprodujo correctamente")
            return
        }
        let ratio = rmsTri / rmsBd

        print("=== [VolumeCalibrate regresión] RMS_bd=\(String(format: "%.6f", rmsBd)), RMS_tri=\(String(format: "%.6f", rmsTri)), ratio=\(String(format: "%.6f", ratio))")
        print("=== Rango aceptable: [\(String(format: "%.6f", toleranceLow)), \(String(format: "%.6f", toleranceHigh))]  (Strudel ref: \(String(format: "%.6f", strudelRatio)))")

        XCTAssertGreaterThanOrEqual(ratio, toleranceLow,
            "ratio synth(triangle)/bd=\(ratio) es menor que el mínimo aceptable \(toleranceLow) (Strudel ref: \(strudelRatio) ±30%)")
        XCTAssertLessThanOrEqual(ratio, toleranceHigh,
            "ratio synth(triangle)/bd=\(ratio) supera el máximo aceptable \(toleranceHigh) (Strudel ref: \(strudelRatio) ±30%)")
    }
}
