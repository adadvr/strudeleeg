// ---------------------------------------------------------------------------
// VolumeCalibrate — Calibración empírica de synthHeadroom.
//
// Mide el RMS de salida del MiniEngine para cada patrón de synth y para el
// kick drum, luego compara los ratios con los valores de referencia medidos
// desde Strudel (WebProbe --record). Calcula el factor synthHeadroom necesario
// para igualar los ratios de Strudel.
//
// USO: swift run VolumeCalibrate
//
// MÉTODO:
//   Para cada patrón, instala un tap en mainMixerNode, deja correr el motor
//   3 segundos (descartando el warmup inicial 0.3s), calcula RMS de los samples
//   capturados y luego detiene el motor.
//
// IMPORTANTE: este harness produce audio por los altavoces (igual que
//   LiveEngineTests). Es inevitable para medir el tap real del mixer.
// ---------------------------------------------------------------------------

import AVFoundation
import Foundation
import MiniEngine

// MARK: - Samples URL map (cargados del bundle de recursos SPM)

/// Enumera recursivamente la carpeta Samples/ y construye el mapa
/// nombre→URL que usa PatternScheduler. Equivale a lo que hace EngineAdapter
/// en la app completa.
///
/// Busca la carpeta Samples/ en:
///  1. Argumento de línea de comandos (si se pasa)
///  2. Bundle SPM (DemoStrudel_VolumeCalibrate.bundle/Samples/)
///  3. Bundle principal
///  4. Directorio del ejecutable
func buildSampleURLs() -> [String: URL] {
    // 1. Argumento explícito
    let cliArgs = CommandLine.arguments
    var samplesDir: URL? = nil

    if cliArgs.count > 1 {
        samplesDir = URL(fileURLWithPath: cliArgs[1])
    }

    // 2. Bundle SPM: buscar el .bundle junto al ejecutable
    if samplesDir == nil {
        let execURL = URL(fileURLWithPath: cliArgs[0])
        let execDir = execURL.deletingLastPathComponent()
        // El bundle SPM se llama DemoStrudel_VolumeCalibrate.bundle
        let bundlePath = execDir.appendingPathComponent("DemoStrudel_VolumeCalibrate.bundle")
        let candidate = bundlePath.appendingPathComponent("Samples")
        if FileManager.default.fileExists(atPath: candidate.path) {
            samplesDir = candidate
        }
    }

    // 3. Bundle principal
    if samplesDir == nil, let resURL = Bundle.main.resourceURL {
        let candidate = resURL.appendingPathComponent("Samples")
        if FileManager.default.fileExists(atPath: candidate.path) {
            samplesDir = candidate
        }
    }

    guard let samplesDir = samplesDir else {
        print("[VolumeCalibrate] ERROR: no se encontró la carpeta Samples/")
        print("[VolumeCalibrate] Pasa la ruta explícita: swift run VolumeCalibrate <ruta/a/Samples>")
        return [:]
    }

    print("[VolumeCalibrate] Usando Samples/: \(samplesDir.path)")
    var map: [String: URL] = [:]

    guard let enumerator = FileManager.default.enumerator(
        at: samplesDir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        print("[VolumeCalibrate] ERROR: no se pudo enumerar \(samplesDir.path)")
        return [:]
    }

    for case let url as URL in enumerator {
        guard let res = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              res.isRegularFile == true,
              url.pathExtension.lowercased() == "wav" else { continue }

        // Clave: nombre base sin extensión (flat) o subfolder_nombre (banked)
        let relative = url.path.replacingOccurrences(of: samplesDir.path + "/", with: "")
        let components = relative.components(separatedBy: "/")
        let key: String
        if components.count == 1 {
            // Flat: "bd.wav" → "bd"
            key = url.deletingPathExtension().lastPathComponent
        } else {
            // Banked: "tr909/bd.wav" → "tr909_bd"
            let dir = components.dropLast().joined(separator: "_")
            let base = url.deletingPathExtension().lastPathComponent
            key = "\(dir)_\(base)"
        }
        map[key] = url
    }
    return map
}

// MARK: - RMS measurement via live mixer tap

/// Mide el RMS de salida del mainMixer para un patrón dado.
/// - warmup: segundos de audio inicial que se descartan (0.3s por defecto).
/// - duration: cuántos segundos de audio útil se capturan.
/// Devuelve el RMS (0.0 si no se captura audio).
func measureRMS(
    code: String,
    duration: Double,
    warmup: Double = 0.3,
    sampleURLs: [String: URL]
) -> Double {
    let engine = MiniEngine(sampleURLs: sampleURLs)
    var captured: [Float] = []
    let lock = NSLock()

    engine.play(code: code)

    let av = engine.audioEngineForTesting
    let fmt = av.mainMixerNode.outputFormat(forBus: 0)
    let sr = fmt.sampleRate

    // Pequeño delay para asegurar que el engine esté arrancado antes del tap
    Thread.sleep(forTimeInterval: 0.1)

    av.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
        lock.lock(); defer { lock.unlock() }
        if let ch = buf.floatChannelData?[0] {
            captured.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }
    }

    // Esperar warmup + duración
    RunLoop.current.run(until: Date(timeIntervalSinceNow: warmup + duration))

    av.mainMixerNode.removeTap(onBus: 0)
    engine.stop()

    lock.lock(); let samples = captured; lock.unlock()

    guard samples.count > Int(warmup * sr) else {
        print("    [WARN] Pocos samples capturados: \(samples.count) (necesitamos >\(Int(warmup * sr)))")
        return 0.0
    }

    // Descartar el warmup inicial
    let skipFrames = Int(warmup * sr)
    let slice = samples.dropFirst(skipFrames)
    let sumSq = slice.reduce(0.0) { $0 + Double($1 * $1) }
    return sqrt(sumSq / Double(slice.count))
}

// MARK: - Main calibration routine

print("[VolumeCalibrate] Iniciando…")
let sampleURLs = buildSampleURLs()
print("[VolumeCalibrate] Muestras cargadas: \(sampleURLs.count) archivos")
if sampleURLs.isEmpty {
    print("[VolumeCalibrate] ERROR FATAL: sin samples. Verifica la ruta del bundle.")
    exit(1)
}
print("[VolumeCalibrate] Primer test rápido de MiniEngine…")
do {
    let testEngine = MiniEngine(sampleURLs: sampleURLs)
    print("[VolumeCalibrate] MiniEngine creado OK")
    testEngine.play(code: #"note("a4").sound("sine")"#)
    print("[VolumeCalibrate] play() OK")
    Thread.sleep(forTimeInterval: 0.2)
    testEngine.stop()
    print("[VolumeCalibrate] stop() OK")
}

// ─── Patrones a medir ────────────────────────────────────────────────────────
// Nota: el cps default es 0.5 (1 ciclo = 2s). Para bd*4 eso da 4 beats en 2s,
// suficiente para capturar varias repeticiones en 3s de grabación.

let patterns: [(name: String, code: String)] = [
    ("bd (sample)",          #"s("bd*4").gain(0.95)"#),
    ("triangle (synth)",     #"note("a4").sound("triangle").gain(0.5)"#),
    ("sawtooth (synth)",     #"note("a4").sound("sawtooth").gain(0.5)"#),
    ("sine (synth)",         #"note("a4").sound("sine").gain(0.5)"#),
    ("square (synth)",       #"note("a4").sound("square").gain(0.5)"#),
]

print("\n=== MiniEngine RMS measurement (synthHeadroom=0.3, actual) ===")
print("Capturando 3s de audio por patrón (warmup 0.3s descartado)…")
print("(El audio se oirá por los altavoces — es inevitable para el tap real)\n")

var rmsMap: [String: Double] = [:]

for (name, code) in patterns {
    print("  Midiendo: \(name)…")
    let rms = measureRMS(code: code, duration: 3.0, warmup: 0.3, sampleURLs: sampleURLs)
    rmsMap[name] = rms
    print("    RMS = \(String(format: "%.6f", rms))")
    // Pequeña pausa entre patrones para dejar el AVAudioEngine liberar recursos
    Thread.sleep(forTimeInterval: 0.5)
}

// ─── Resultados y comparación ────────────────────────────────────────────────

let rms_bd       = rmsMap["bd (sample)"]       ?? 0.0
let rms_tri      = rmsMap["triangle (synth)"]  ?? 0.0
let rms_saw      = rmsMap["sawtooth (synth)"]  ?? 0.0
let rms_sine     = rmsMap["sine (synth)"]      ?? 0.0
let rms_square   = rmsMap["square (synth)"]    ?? 0.0

// ─── Valores de referencia Strudel (medidos con WebProbe --record, 2026-07-23) ─
// Metodología: WKUserScript en .atDocumentStart parchea AudioNode.prototype.connect;
// ScriptProcessorNode(4096, 2, 2) captura canal L. 3 segundos, warmup 0.3s descartado.
// sampleRate=44100 Hz en todos los casos.
//
// Patrón                                       RMS_Strudel
// ─────────────────────────────────────────────────────────
// s("bd*4").gain(0.95)                         0.213416
// note("a4").sound("triangle").gain(0.5)       0.052425
// note("a4").sound("sawtooth").gain(0.5)       0.044148
// note("a4").sound("sine").gain(0.5)           0.064196
// note("a4").sound("square").gain(0.5)         0.076606
//
// Ratios synth/bd en Strudel:
// triangle/bd = 0.052425 / 0.213416 = 0.24566
// sawtooth/bd = 0.044148 / 0.213416 = 0.20683
// sine/bd     = 0.064196 / 0.213416 = 0.30082
// square/bd   = 0.076606 / 0.213416 = 0.35897

let strudelRMS_bd     = 0.213416
let strudelRMS_tri    = 0.052425
let strudelRMS_saw    = 0.044148
let strudelRMS_sine   = 0.064196
let strudelRMS_square = 0.076606

let strudelRatio_tri    = strudelRMS_tri    / strudelRMS_bd
let strudelRatio_saw    = strudelRMS_saw    / strudelRMS_bd
let strudelRatio_sine   = strudelRMS_sine   / strudelRMS_bd
let strudelRatio_square = strudelRMS_square / strudelRMS_bd

// ─── Ratios del MiniEngine con headroom=0.3 ──────────────────────────────────
let miniRatio_tri    = rms_bd > 0 ? rms_tri    / rms_bd : 0.0
let miniRatio_saw    = rms_bd > 0 ? rms_saw    / rms_bd : 0.0
let miniRatio_sine   = rms_bd > 0 ? rms_sine   / rms_bd : 0.0
let miniRatio_square = rms_bd > 0 ? rms_square / rms_bd : 0.0

// Helper: pad string to a fixed width using spaces
func col(_ s: String, _ w: Int) -> String {
    if s.count >= w { return String(s.prefix(w)) }
    return s + String(repeating: " ", count: w - s.count)
}

print("\n")
print(String(repeating: "=", count: 80))
print("TABLA STRUDEL (referencia WebProbe --record, 2026-07-23)")
print(String(repeating: "-", count: 80))
print("\(col("Patrón", 40))  \(col("RMS", 10))  \(col("Ratio/bd", 12))")
print(String(repeating: "-", count: 80))
print("\(col("s(\"bd*4\").gain(0.95)", 40))  \(String(format: "%10.6f", strudelRMS_bd))  \(col("1.000000", 12))")
print("\(col("sound(\"triangle\").gain(0.5)", 40))  \(String(format: "%10.6f", strudelRMS_tri))  \(String(format: "%12.6f", strudelRatio_tri))")
print("\(col("sound(\"sawtooth\").gain(0.5)", 40))  \(String(format: "%10.6f", strudelRMS_saw))  \(String(format: "%12.6f", strudelRatio_saw))")
print("\(col("sound(\"sine\").gain(0.5)", 40))  \(String(format: "%10.6f", strudelRMS_sine))  \(String(format: "%12.6f", strudelRatio_sine))")
print("\(col("sound(\"square\").gain(0.5)", 40))  \(String(format: "%10.6f", strudelRMS_square))  \(String(format: "%12.6f", strudelRatio_square))")
print(String(repeating: "=", count: 80))

print("\n")
print(String(repeating: "=", count: 80))
print("TABLA MiniEngine (synthHeadroom=0.3, ANTES de calibración)")
print(String(repeating: "-", count: 80))
print("\(col("Patrón", 40))  \(col("RMS", 10))  \(col("Ratio/bd", 12))  \(col("vs Strudel", 10))")
print(String(repeating: "-", count: 80))
print("\(col("s(\"bd*4\").gain(0.95)", 40))  \(String(format: "%10.6f", rms_bd))  \(col("1.000000", 12))  \(col("-", 10))")

func pct(_ x: Double) -> String { String(format: "%+.0f%%", (x - 1.0) * 100.0) }

if rms_bd > 0 {
    print("\(col("triangle gain(0.5)", 40))  \(String(format: "%10.6f", rms_tri))  \(String(format: "%12.6f", miniRatio_tri))  \(col(miniRatio_tri > 0 ? pct(miniRatio_tri / strudelRatio_tri) : "N/A", 10))")
    print("\(col("sawtooth gain(0.5)", 40))  \(String(format: "%10.6f", rms_saw))  \(String(format: "%12.6f", miniRatio_saw))  \(col(miniRatio_saw > 0 ? pct(miniRatio_saw / strudelRatio_saw) : "N/A", 10))")
    print("\(col("sine     gain(0.5)", 40))  \(String(format: "%10.6f", rms_sine))  \(String(format: "%12.6f", miniRatio_sine))  \(col(miniRatio_sine > 0 ? pct(miniRatio_sine / strudelRatio_sine) : "N/A", 10))")
    print("\(col("square   gain(0.5)", 40))  \(String(format: "%10.6f", rms_square))  \(String(format: "%12.6f", miniRatio_square))  \(col(miniRatio_square > 0 ? pct(miniRatio_square / strudelRatio_square) : "N/A", 10))")
}
print(String(repeating: "=", count: 80))

// ─── Calcular el factor de corrección necesario ───────────────────────────────
// La relación entre synthHeadroom actual y el necesario:
//   ratio_mini = ratio_strudel × (headroom_nuevo / headroom_actual)
//   headroom_nuevo = headroom_actual × (ratio_strudel / ratio_mini)
//
// Usamos el promedio de los 4 waveforms para el factor global.

let currentHeadroom = 0.3

var corrections: [Double] = []
if miniRatio_tri > 0    { corrections.append(strudelRatio_tri    / miniRatio_tri) }
if miniRatio_saw > 0    { corrections.append(strudelRatio_saw    / miniRatio_saw) }
if miniRatio_sine > 0   { corrections.append(strudelRatio_sine   / miniRatio_sine) }
if miniRatio_square > 0 { corrections.append(strudelRatio_square / miniRatio_square) }

let avgCorrection = corrections.isEmpty ? 1.0 : corrections.reduce(0, +) / Double(corrections.count)
let newHeadroom = currentHeadroom * avgCorrection

print("\n")
print(String(repeating: "=", count: 80))
print("ANÁLISIS DE CALIBRACIÓN")
print(String(repeating: "-", count: 80))
print("synthHeadroom actual:     \(String(format: "%.4f", currentHeadroom))")
print("Factor de corrección medio (strudel/mini): \(String(format: "%.4f", avgCorrection))")
print("synthHeadroom propuesto:  \(String(format: "%.4f", newHeadroom))")

// Verificar si algún waveform necesita factor individual (diferencia >30% entre ellos)
let maxCorr = corrections.max() ?? 1.0
let minCorr = corrections.min() ?? 1.0
let spreadRatio = maxCorr > 0 ? maxCorr / minCorr : 1.0
print("Spread de correcciones por waveform: \(String(format: "%.2fx", spreadRatio)) (max/min)")

if spreadRatio > 1.5 {
    print("  → Spread >1.5x: los waveforms necesitan factores individuales.")
    let names = ["triangle", "sawtooth", "sine", "square"]
    let ratios = [miniRatio_tri, miniRatio_saw, miniRatio_sine, miniRatio_square]
    let strudelRatios = [strudelRatio_tri, strudelRatio_saw, strudelRatio_sine, strudelRatio_square]
    for i in 0..<names.count {
        if ratios[i] > 0 {
            let corr = strudelRatios[i] / ratios[i]
            let wfHead = currentHeadroom * corr
            print("    \(names[i]): corrección=\(String(format: "%.4f", corr)), headroom propuesto=\(String(format: "%.4f", wfHead))")
        }
    }
} else {
    print("  → Spread ≤1.5x: un factor global es suficiente.")
}

// ─── Tolerancia ±30% (≈±2.3 dB) ─────────────────────────────────────────────
print("\n")
print("VERIFICACIÓN DE TOLERANCIA (±30% del ratio Strudel):")
func checkTolerance(name: String, mini: Double, strudel: Double) -> Bool {
    guard mini > 0 else { print("  \(name): sin datos"); return false }
    let devRatio = mini / strudel   // debe estar en [0.7, 1.3]
    let ok = devRatio >= 0.7 && devRatio <= 1.3
    let dB = 20.0 * log10(devRatio)
    print("  \(name): mini/strudel=\(String(format: "%.3f", devRatio)) (\(String(format: "%+.1f dB", dB))) → \(ok ? "OK ✓" : "FUERA ✗")")
    return ok
}

let t1 = checkTolerance(name: "triangle", mini: miniRatio_tri,    strudel: strudelRatio_tri)
let t2 = checkTolerance(name: "sawtooth", mini: miniRatio_saw,    strudel: strudelRatio_saw)
let t3 = checkTolerance(name: "sine",     mini: miniRatio_sine,   strudel: strudelRatio_sine)
let t4 = checkTolerance(name: "square",   mini: miniRatio_square, strudel: strudelRatio_square)
let allOK = t1 && t2 && t3 && t4

print("\nConclusion: synthHeadroom=0.3 \(allOK ? "✓ YA está dentro de ±30%" : "✗ NECESITA ajuste")")
if !allOK {
    print("  Acción: cambiar synthHeadroom de 0.3 a \(String(format: "%.4f", newHeadroom))")
    let roundedNew = (newHeadroom * 1000).rounded() / 1000.0
    print("  Redondeado a 3 decimales: \(String(format: "%.3f", roundedNew))")
}
print(String(repeating: "=", count: 80))

exit(0)
