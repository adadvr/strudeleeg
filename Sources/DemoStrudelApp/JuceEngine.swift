import Foundation
import AVFoundation
import StrudelJuceC

// ---------------------------------------------------------------------------
// JuceEngine — wrapper Swift RAII sobre el C API de StrudelJuce (motor JUCE C++).
//
// Fase 0: solo lifecycle + test tone, para verificar que el xcframework enlaza
// y produce audio desde Swift. En Fases 2-4 crecerá con scheduleSynth/
// scheduleSample/orbit FX y se envolverá en `JuceEngineAdapter: AudioDemoEngine`
// (backend JUCE de MiniEngine).
// ---------------------------------------------------------------------------
final class JuceEngine {

    private let handle: OpaquePointer

    init() {
        // strudel_engine_create devuelve StrudelEngineHandle* → OpaquePointer en Swift.
        handle = strudel_engine_create()
    }

    deinit {
        strudel_engine_destroy(handle)
    }

    /// Abre el device de audio por defecto. Devuelve true si quedó corriendo.
    @discardableResult
    func start() -> Bool {
        return strudel_engine_start(handle) == 0
    }

    func stop() {
        strudel_engine_stop(handle)
    }

    var isRunning: Bool {
        strudel_engine_is_running(handle) != 0
    }

    /// Test tone de la Fase 0 (verificación de enlace end-to-end).
    func setTestTone(_ enabled: Bool, frequency: Float = 440) {
        strudel_engine_set_test_tone(handle, enabled ? 1 : 0, frequency)
    }

    // MARK: - Fase 2: scheduling de synth

    /// Agenda una voz de oscilador `delaySeconds` en el futuro. Llamar desde el
    /// scheduler (control thread), nunca desde el audio thread.
    func scheduleSynth(
        delaySeconds: Double,
        waveform: String,
        freq: Double,
        gain: Double,
        attack: Double, decay: Double, sustain: Double, release: Double,
        durationSec: Double,
        lpfHz: Double, hpfHz: Double, resonanceQ: Double,
        pan: Double, crushBits: Double,
        lpenvOct: Double, hpenvOct: Double,
        postgain: Double, orbit: Int
    ) {
        strudel_engine_schedule_synth(
            handle, delaySeconds, waveform,
            freq, gain, attack, decay, sustain, release, durationSec,
            lpfHz, hpfHz, resonanceQ, pan, crushBits, lpenvOct, hpenvOct, postgain,
            Int32(orbit))
    }

    func allNotesOff() {
        strudel_engine_all_notes_off(handle)
    }

    // MARK: - Fase 3: samples

    func hasSample(_ key: String) -> Bool {
        strudel_engine_has_sample(handle, key) != 0
    }

    /// Carga un AVAudioPCMBuffer (float) en el banco JUCE bajo `key`.
    func loadSample(key: String, buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let frames = Int64(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sr = buffer.format.sampleRate
        let ch0 = chData[0]
        let ch1: UnsafeMutablePointer<Float>? = channels >= 2 ? chData[1] : nil
        strudel_engine_load_sample(handle, key, ch0, ch1,
                                   Int32(channels >= 2 ? 2 : 1), frames, sr)
    }

    func scheduleSample(
        delaySeconds: Double, key: String,
        playbackRatio: Double, gain: Double, postgain: Double,
        beginFrac: Double, endFrac: Double,
        lpfHz: Double, hpfHz: Double, resonanceQ: Double,
        pan: Double, crushBits: Double,
        hasADSR: Bool, attack: Double, decay: Double, sustain: Double,
        release: Double, durationSec: Double, orbit: Int
    ) {
        strudel_engine_schedule_sample(
            handle, delaySeconds, key,
            playbackRatio, gain, postgain, beginFrac, endFrac,
            lpfHz, hpfHz, resonanceQ, pan, crushBits,
            hasADSR ? 1 : 0, attack, decay, sustain, release, durationSec,
            Int32(orbit))
    }

    // MARK: - Fase 4: FX de orbit

    func setOrbitFX(orbit: Int, room: Double, size: Double,
                    delayWet: Double, delayTime: Double, delayFeedback: Double) {
        strudel_engine_set_orbit_fx(handle, Int32(orbit), room, size, delayWet, delayTime, delayFeedback)
    }
}
