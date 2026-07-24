import Foundation
import AVFoundation
import MiniEngine

// ---------------------------------------------------------------------------
// JucePatternScheduler — bucle de scheduling para el backend JUCE.
//
// Reutiliza el motor de patrones Swift de MiniEngine (CodeParser +
// PatternEventExtractor) exactamente igual que el backend AVAudioEngine, pero
// en vez de tocar nodos AVAudio despacha cada evento al motor JUCE (C API) con
// un delay relativo. Mismo tick de 100 ms y lookahead de 400 ms.
//
// Fase 2: solo despacha voces de synth (sine/sawtooth/square/triangle). Los
// samples y los FX de orbit (reverb/delay/duck) llegan en Fases 3-4.
// ---------------------------------------------------------------------------
final class JucePatternScheduler {

    private let engine: JuceEngine

    private var cps: Double = 0.5
    private var cycleSeconds: Double { 1.0 / cps }
    private static let lookahead: Double = 0.4
    private static let timerInterval: Double = 0.1
    private static let defaultOrbit: Int = 1

    private var pattern: ControlPattern?
    private var isRunning = false
    private var startHostTime: Double = 0
    private var scheduledUpTo: Double = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.strudeljuce.scheduler", qos: .userInteractive)

    /// Reportado a la UI cuando el parser falla.
    var onParseError: ((String) -> Void)?

    /// Mapa de samples locales del bundle: key (p.ej. "bd", "tr909_bd") → URL WAV.
    private let sampleURLs: [String: URL]
    /// Keys ya cargadas en el motor JUCE (evita recargar). Para remotos: "\(name):\(idx)"; locales: el nombre.
    private var loadedSamples: Set<String> = []
    /// Gestor de bancos remotos (github: / https:) compartido con el backend AVAudio.
    private let bankManager = SampleBankManager.shared

    init(engine: JuceEngine, sampleURLs: [String: URL]) {
        self.engine = engine
        self.sampleURLs = sampleURLs
    }

    /// Decodifica un WAV a AVAudioPCMBuffer float (estándar de la app).
    private func decodeWav(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        return buf
    }

    /// Pre-escanea el patrón, carga en JUCE los samples remotos (vía SampleBankManager)
    /// y locales (bundle WAV) referenciados. Los synths se ignoran aquí.
    /// - Remotos: key = "\(name):\(idx)" (un slot por variación).
    /// - Locales: key = nombre plano (como hoy), solo variación 0.
    private func preloadSamples(for pattern: ControlPattern) {
        let previewHaps = pattern.queryArc(Rational(0), Rational(4))

        // Recolectar pares (nombre, variationIdx) únicos de los haps de sample.
        var remotePairs: [(name: String, index: Int)] = []
        var seenPairs: Set<String> = []  // "name:idx" para dedupe
        for hap in previewHaps {
            let events = PatternEventExtractor.events(
                haps: [hap], cycleSeconds: cycleSeconds, startHostTime: 0,
                windowStart: -1e9, windowEnd: 1e9, defaultOrbit: Self.defaultOrbit)
            for ev in events where !ev.isSynth {
                let pairKey = "\(ev.sName):\(ev.variationIdx)"
                if seenPairs.insert(pairKey).inserted {
                    remotePairs.append((name: ev.sName, index: ev.variationIdx))
                }
            }
        }

        // Prefetch remoto con espera acotada (cache-hits de disco quedan listos de inmediato;
        // los misses de red siguen async y sus eventos se saltan hasta que estén listos).
        bankManager.prefetchAndWait(names: remotePairs, timeout: 0.5)

        // Cargar cada par en el motor JUCE (dedupe por key final).
        for (name, idx) in remotePairs {
            let remoteKey = "\(name):\(idx)"
            if loadedSamples.contains(remoteKey) { continue }

            if let buf = bankManager.buffer(forName: name, index: idx) {
                // Sample remoto disponible: cargar con key "nombre:idx".
                engine.loadSample(key: remoteKey, buffer: buf)
                loadedSamples.insert(remoteKey)
            } else if !loadedSamples.contains(name) {
                // Fallback: intentar bundle local (variación 0 implícita; key = nombre plano).
                if let url = sampleURLs[name], let buf = decodeWav(url) {
                    engine.loadSample(key: name, buffer: buf)
                    loadedSamples.insert(name)
                }
            }
        }

        // P1 (Soundfonts GM): prefetch de instrumentos GM detectados en el patrón.
        // Los nombres gm_ se excluyen del SampleBankManager; se manejan con SoundfontManager.
        let gmPairs = previewHaps.compactMap { hap -> (name: String, index: Int)? in
            let events = PatternEventExtractor.events(
                haps: [hap], cycleSeconds: cycleSeconds, startHostTime: 0,
                windowStart: -1e9, windowEnd: 1e9, defaultOrbit: Self.defaultOrbit)
            for ev in events where !ev.isSynth && SoundfontManager.shared.isSoundfont(ev.sName) {
                return (ev.sName, ev.variationIdx)
            }
            return nil
        }
        if !gmPairs.isEmpty {
            let gmNames = Array(Set(gmPairs.map { $0.name }))
            SoundfontManager.shared.prefetchAndWait(names: gmNames, timeout: 0.5)
            // Cargar los buffers ya disponibles en JUCE (key por nota MIDI)
            // Se hace también de forma lazy en scheduleWindow.
        }
    }

    private func hostTimeNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }

    func play(code: String) {
        stop()

        let parser = CodeParser()
        let result: ParseResult
        do {
            result = try parser.parseWithTempo(code)
        } catch {
            onParseError?("\(error)")
            return
        }
        if let c = result.cps { cps = max(0.0001, c) }
        pattern = result.pattern

        // Fase 3 (remotos): registrar los manifests declarados con samples('github:...').
        for urlStr in result.manifestURLs {
            do { _ = try bankManager.registerSync(manifestURL: urlStr) }
            catch { print("[JuceScheduler] No se pudo registrar manifest \(urlStr): \(error)") }
        }

        // Fase 3: precarga de samples (locales del bundle y remotos) referenciados en el patrón.
        preloadSamples(for: result.pattern)

        _ = engine.start()

        startHostTime = hostTimeNow()
        scheduledUpTo = startHostTime
        isRunning = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(),
                   repeating: .milliseconds(Int(Self.timerInterval * 1000)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        engine.allNotesOff()
    }

    private func tick() {
        guard isRunning, let pattern = pattern else { return }
        let now     = hostTimeNow()
        let horizon = now + Self.lookahead
        scheduleWindow(pattern: pattern, from: scheduledUpTo, to: horizon)
        scheduledUpTo = horizon
    }

    private func scheduleWindow(pattern: ControlPattern, from windowStart: Double, to windowEnd: Double) {
        let elapsed0 = windowStart - startHostTime
        let elapsed1 = windowEnd   - startHostTime
        let cycleBegin = Rational(approximating: elapsed0 / cycleSeconds)
        let cycleEnd   = Rational(approximating: elapsed1 / cycleSeconds)

        let haps = pattern.queryArc(cycleBegin, cycleEnd)

        // Misma extracción neutral que usa el backend AVAudio (Fase 1).
        let events = PatternEventExtractor.events(
            haps:          haps,
            cycleSeconds:  cycleSeconds,
            startHostTime: startHostTime,
            windowStart:   windowStart,
            windowEnd:     windowEnd,
            defaultOrbit:  Self.defaultOrbit
        )

        let now = hostTimeNow()
        for ev in events {
            let delay = max(0, ev.absoluteTime - now)

            // P3: gain efectivo = gain × velocity (velocity=1.0 por defecto = sin cambio).
            let effectiveGain = ev.gain * ev.velocity

            // FX de orbit (last event wins): room/size → reverb, delay → delay bus.
            if ev.room != nil || ev.size != nil || ev.delay != nil {
                engine.setOrbitFX(
                    orbit:         ev.orbit,
                    room:          ev.room  ?? 0,
                    size:          ev.size  ?? 0.5,
                    delayWet:      ev.delay ?? 0,
                    delayTime:     ev.delaytime ?? 0.25,
                    delayFeedback: ev.delayfeedback ?? 0.4
                )
            }

            if ev.isSynth {
                let midi = ev.midiNote ?? Double(synthDefaultMIDI)
                engine.scheduleSynth(
                    delaySeconds: delay,
                    waveform:     ev.sName,
                    freq:         synthFrequency(midi: midi),
                    gain:         effectiveGain,
                    attack:       ev.attack   ?? ADSRDefaults.attack,
                    decay:        ev.decay    ?? ADSRDefaults.decay,
                    sustain:      ev.sustain  ?? ADSRDefaults.sustain,
                    release:      ev.release  ?? ADSRDefaults.release,
                    durationSec:  ev.durationSec,
                    lpfHz:        ev.cutoff    ?? -1,
                    hpfHz:        ev.hpf       ?? -1,
                    resonanceQ:   ev.resonance ?? -1,
                    pan:          ev.pan       ?? -1,
                    crushBits:    ev.crush     ?? 0,
                    lpenvOct:     ev.lpenv,
                    hpenvOct:     ev.hpenv,
                    postgain:     ev.postgain,
                    orbit:        ev.orbit
                )
            } else if SoundfontManager.shared.isSoundfont(ev.sName) {
                // P1 (Soundfonts GM): resolución de instrumento GM.
                // SoundfontManager elige zona por keyRange y decodifica el MP3.
                let midi = Int(ev.midiNote ?? 60)
                guard let (sfBuf, sfRoot) = SoundfontManager.shared.resolve(name: ev.sName, midi: midi) else {
                    continue  // no listo todavía → saltar evento
                }
                // Key única por (nombre, nota) para deduplicar cargas en JUCE.
                let gmKey = "\(ev.sName):\(midi)"
                if !loadedSamples.contains(gmKey) {
                    engine.loadSample(key: gmKey, buffer: sfBuf)
                    loadedSamples.insert(gmKey)
                }
                // Repitch: 2^((midi - rootMidi) / 12) × speed
                let gmRate = pow(2.0, Double(midi - sfRoot) / 12.0) * (ev.speed ?? 1.0)
                let hasADSR = ev.hasExplicitADSR
                engine.scheduleSample(
                    delaySeconds: delay,
                    key:          gmKey,
                    playbackRatio: gmRate,
                    gain:         effectiveGain,
                    postgain:     ev.postgain,
                    beginFrac:    ev.begin ?? -1,
                    endFrac:      ev.end   ?? -1,
                    lpfHz:        ev.cutoff    ?? -1,
                    hpfHz:        ev.hpf       ?? -1,
                    resonanceQ:   ev.resonance ?? -1,
                    pan:          ev.pan       ?? -1,
                    crushBits:    ev.crush     ?? 0,
                    hasADSR:      hasADSR,
                    attack:       ev.attack  ?? ADSRDefaults.attack,
                    decay:        ev.decay   ?? ADSRDefaults.decay,
                    sustain:      ev.sustain ?? ADSRDefaults.sustain,
                    release:      ev.release ?? ADSRDefaults.release,
                    durationSec:  ev.durationSec,
                    orbit:        ev.orbit
                )
            } else {
                // Preferir buffer remoto (con key "nombre:idx"); si no, bundle local.
                let remoteKey = "\(ev.sName):\(ev.variationIdx)"

                // Carga perezosa: un sample remoto que llegó DESPUÉS del prefetch
                // inicial (miss de red) no está aún en el motor. Si el bank ya tiene
                // el buffer, cargarlo ahora (control thread, seguro) para que suene.
                if !engine.hasSample(remoteKey),
                   !loadedSamples.contains(remoteKey),
                   let buf = bankManager.buffer(forName: ev.sName, index: ev.variationIdx) {
                    engine.loadSample(key: remoteKey, buffer: buf)
                    loadedSamples.insert(remoteKey)
                }

                let key: String
                let base: Int
                if engine.hasSample(remoteKey) {
                    key  = remoteKey
                    base = 36  // arrays planos remotos: base C2 (convención Strudel)
                } else if engine.hasSample(ev.sName) {
                    key  = ev.sName
                    base = PatternScheduler.localNoteBases[ev.sName] ?? 36
                } else {
                    continue  // ni remoto ni local cargado → saltar evento
                }
                let noteRate: Double = ev.midiNote.map { pow(2.0, ($0 - Double(base)) / 12.0) } ?? 1.0
                let ratio = noteRate * (ev.speed ?? 1.0)
                let hasADSR = ev.hasExplicitADSR

                engine.scheduleSample(
                    delaySeconds: delay,
                    key:          key,
                    playbackRatio: ratio,
                    gain:         effectiveGain,
                    postgain:     ev.postgain,
                    beginFrac:    ev.begin ?? -1,
                    endFrac:      ev.end   ?? -1,
                    lpfHz:        ev.cutoff    ?? -1,
                    hpfHz:        ev.hpf       ?? -1,
                    resonanceQ:   ev.resonance ?? -1,
                    pan:          ev.pan       ?? -1,
                    crushBits:    ev.crush     ?? 0,
                    hasADSR:      hasADSR,
                    attack:       ev.attack  ?? ADSRDefaults.attack,
                    decay:        ev.decay   ?? ADSRDefaults.decay,
                    sustain:      ev.sustain ?? ADSRDefaults.sustain,
                    release:      ev.release ?? ADSRDefaults.release,
                    durationSec:  ev.durationSec,
                    orbit:        ev.orbit
                )
            }
        }
    }
}
