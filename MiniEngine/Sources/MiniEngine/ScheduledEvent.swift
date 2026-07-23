import Foundation

// ---------------------------------------------------------------------------
// ScheduledEvent — evento de audio neutral (agnóstico de backend) extraído de
// un Hap de ControlPattern. Captura todos los campos que hoy lee inline
// PatternScheduler.scheduleWindow(), para que TANTO el backend AVAudioEngine
// COMO el backend JUCE consuman exactamente la misma lógica de extracción y no
// diverjan (Fase 1 del tercer motor).
//
// La extracción es pura: no toca audio. Cada backend traduce el evento a su
// propia cadena (AVAudio nodes / JUCE voices) en su dispatch.
// ---------------------------------------------------------------------------

public struct ScheduledEvent {
    public let sName:        String     // nombre resuelto (con prefijo bank_ si aplica)
    public let layerIdx:     Int        // rama del stack (_layer) → cadena aislada
    public let variationIdx: Int        // :n variation
    public let isSynth:      Bool       // synth vs sample
    public let absoluteTime: Double     // onset en segundos de host
    public let durationSec:  Double     // duración del hap (para ADSR)

    public let midiNote:      Double?
    public let gain:          Double
    public let room:          Double?
    public let cutoff:        Double?   // cutoff | lpf
    public let hpf:           Double?
    public let resonance:     Double?
    public let pan:           Double?
    public let delay:         Double?
    public let delaytime:     Double?
    public let delayfeedback: Double?
    public let speed:         Double?
    public let orbit:         Int
    public let attack:        Double?
    public let decay:         Double?
    public let sustain:       Double?
    public let release:       Double?
    public let shape:         Double?
    public let distort:       Double?
    public let crush:         Double?
    public let vowel:         String?
    public let begin:         Double?
    public let end:           Double?
    public let duckOrbit:     Double?
    public let duckAttack:    Double
    public let duckDepth:     Double
    public let lpenv:         Double
    public let hpenv:         Double
    public let postgain:      Double
    public let size:          Double?

    /// True si el usuario fijó explícitamente algún parámetro ADSR. Cuando es
    /// false, los samples NO aplican envelope (backward-compat: mismo sonido).
    public var hasExplicitADSR: Bool {
        attack != nil || decay != nil || sustain != nil || release != nil
    }
}

public enum PatternEventExtractor {

    /// Extrae los eventos neutrales de una lista de haps ya consultada, aplicando
    /// el mismo filtrado de ventana y las mismas reglas de campos que la versión
    /// original inline de PatternScheduler.scheduleWindow().
    public static func events(
        haps:          [Hap<[String: ControlValue]>],
        cycleSeconds:  Double,
        startHostTime: Double,
        windowStart:   Double,
        windowEnd:     Double,
        defaultOrbit:  Int
    ) -> [ScheduledEvent] {
        var out: [ScheduledEvent] = []
        out.reserveCapacity(haps.count)

        for hap in haps {
            guard let sBase = hap.value["s"]?.stringValue else { continue }

            let bankName = hap.value["bank"]?.stringValue ?? ""
            let sName    = bankName.isEmpty ? sBase : "\(bankName)_\(sBase)"
            let layerIdx = Int(hap.value["_layer"]?.doubleValue ?? 0.0)
            let nIdx     = Int(hap.value["n"]?.doubleValue ?? 0)

            let hapCycleOnset = hap.part.begin
            let hapSeconds    = hapCycleOnset.toDouble * cycleSeconds
            let absoluteTime  = startHostTime + hapSeconds

            guard absoluteTime >= windowStart, absoluteTime < windowEnd else { continue }
            guard absoluteTime >= startHostTime else { continue }

            let hapDurationCycles = (hap.whole ?? hap.part).end.toDouble
                                  - (hap.whole ?? hap.part).begin.toDouble

            out.append(ScheduledEvent(
                sName:         sName,
                layerIdx:      layerIdx,
                variationIdx:  nIdx,
                isSynth:       isSynthName(sName),
                absoluteTime:  absoluteTime,
                durationSec:   hapDurationCycles * cycleSeconds,
                midiNote:      hap.value["note"]?.doubleValue,
                gain:          hap.value["gain"]?.doubleValue ?? 1.0,
                room:          hap.value["room"]?.doubleValue,
                cutoff:        hap.value["cutoff"]?.doubleValue ?? hap.value["lpf"]?.doubleValue,
                hpf:           hap.value["hpf"]?.doubleValue,
                resonance:     hap.value["resonance"]?.doubleValue,
                pan:           hap.value["pan"]?.doubleValue,
                delay:         hap.value["delay"]?.doubleValue,
                delaytime:     hap.value["delaytime"]?.doubleValue,
                delayfeedback: hap.value["delayfeedback"]?.doubleValue,
                speed:         hap.value["speed"]?.doubleValue,
                orbit:         Int(hap.value["orbit"]?.doubleValue ?? Double(defaultOrbit)),
                attack:        hap.value["attack"]?.doubleValue,
                decay:         hap.value["decay"]?.doubleValue,
                sustain:       hap.value["sustain"]?.doubleValue,
                release:       hap.value["release"]?.doubleValue,
                shape:         hap.value["shape"]?.doubleValue,
                distort:       hap.value["distort"]?.doubleValue,
                crush:         hap.value["crush"]?.doubleValue,
                vowel:         hap.value["vowel"]?.stringValue,
                begin:         hap.value["begin"]?.doubleValue,
                end:           hap.value["end"]?.doubleValue,
                duckOrbit:     hap.value["duck"]?.doubleValue,
                duckAttack:    hap.value["duckattack"]?.doubleValue ?? 0.1,
                duckDepth:     hap.value["duckdepth"]?.doubleValue ?? 1.0,
                lpenv:         hap.value["lpenv"]?.doubleValue ?? 0.0,
                hpenv:         hap.value["hpenv"]?.doubleValue ?? 0.0,
                postgain:      hap.value["postgain"]?.doubleValue ?? 1.0,
                size:          hap.value["size"]?.doubleValue
            ))
        }
        return out
    }
}
