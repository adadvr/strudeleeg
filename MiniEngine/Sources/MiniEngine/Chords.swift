// ---------------------------------------------------------------------------
// Chords.swift — P4: sistema de acordes por nombre
//
// API pública:
//   chord("Am")                    → ControlPattern con notas MIDI simultáneas
//   chord("<Am E Dm G>")           → progresión por slowcat
//   chord("Am").anchor("g5")       → fija el registro de referencia (MIDI 79)
//   chord("Am").voicing()          → re-disposición compacta cerca del ancla (default c5=72)
//   chord("<Am E>").anchor("g5").voicing()
//
// Semántica clean-room desde teoría musical pública (intervalos) y
// strudel.cc/learn (comportamiento de voicing/anchor).
// ---------------------------------------------------------------------------

import Foundation

// MARK: - Tabla de calidades de acordes

/// Intervalos en semitonos desde la fundamental para cada calidad de acorde.
/// Basado en teoría musical estándar (no depende de fuente Strudel).
let qualityIntervals: [String: [Int]] = [
    "":       [0, 4, 7],         // mayor (C E G)
    "m":      [0, 3, 7],         // menor (C Eb G)
    "min":    [0, 3, 7],         // alias menor
    "7":      [0, 4, 7, 10],     // dominante 7ª
    "maj7":   [0, 4, 7, 11],     // mayor 7ª
    "M7":     [0, 4, 7, 11],     // alias mayor 7ª
    "m7":     [0, 3, 7, 10],     // menor 7ª
    "min7":   [0, 3, 7, 10],     // alias menor 7ª
    "dim":    [0, 3, 6],         // disminuido
    "o":      [0, 3, 6],         // alias disminuido
    "dim7":   [0, 3, 6, 9],      // disminuido 7ª
    "m7b5":   [0, 3, 6, 10],     // semidisminuido (half-dim)
    "ø":      [0, 3, 6, 10],     // alias semidisminuido
    "aug":    [0, 4, 8],         // aumentado
    "+":      [0, 4, 8],         // alias aumentado
    "sus2":   [0, 2, 7],         // suspendido 2ª
    "sus4":   [0, 5, 7],         // suspendido 4ª
    "sus":    [0, 5, 7],         // alias sus4
    "6":      [0, 4, 7, 9],      // mayor 6ª
    "m6":     [0, 3, 7, 9],      // menor 6ª
    "9":      [0, 4, 7, 10, 14], // dominante 9ª
    "maj9":   [0, 4, 7, 11, 14], // mayor 9ª
    "m9":     [0, 3, 7, 10, 14], // menor 9ª
    "add9":   [0, 4, 7, 14],     // add9 (sin 7ª)
]

/// Nombres de nota raíz reconocidos → número MIDI en octava 3.
/// Soporta sostenidos (#) y bemoles (b/B).
private let rootNoteNames: [String: String] = [
    "C":  "c3",  "C#": "c#3", "Cb": "b2",
    "D":  "d3",  "D#": "d#3", "Db": "d3",   // Db → C#3 equivale a d3-1; calculado por midiNote
    "E":  "e3",  "Eb": "e3",  "E#": "f3",
    "F":  "f3",  "F#": "f#3", "Fb": "e3",
    "G":  "g3",  "G#": "g#3", "Gb": "g3",
    "A":  "a3",  "A#": "a#3", "Ab": "a3",
    "B":  "b3",  "Bb": "b3",  "B#": "c4",
]

// Tabla directa de MIDI para raíces con bemoles (re-calculadas correctamente)
private let rootMidiOverrides: [String: Int] = [
    "Db": 49,  // C#3
    "Eb": 51,  // D#3
    "Gb": 54,  // F#3
    "Ab": 56,  // G#3
    "Bb": 58,  // A#3
    "Cb": 47,  // B2
    "Fb": 52,  // E3
    "E#": 53,  // F3
    "B#": 60,  // C4
]

// MARK: - Parser de símbolos de acorde

/// Parsea un símbolo de acorde como "Am", "C#maj7", "Bb7", "G" etc.
/// Devuelve la lista de MIDI en posición fundamental (octava base 3).
/// Prueba los sufijos de calidad del más largo al más corto para evitar
/// ambigüedades (ej. "m7" no se confunda con "m").
/// Devuelve nil si el símbolo no es reconocido.
public func parseChordSymbol(_ sym: String) -> [Int]? {
    guard !sym.isEmpty else { return nil }

    // Extraer la nota fundamental (1 o 2 caracteres: A, C#, Bb, Eb…)
    var rootStr: String
    var qualityStr: String

    // Raíz de 2 caracteres: letra + # o b
    if sym.count >= 2 {
        let second = sym[sym.index(after: sym.startIndex)]
        if second == "#" || second == "b" {
            rootStr = String(sym.prefix(2))
            qualityStr = String(sym.dropFirst(2))
        } else {
            rootStr = String(sym.prefix(1))
            qualityStr = String(sym.dropFirst(1))
        }
    } else {
        rootStr = String(sym.prefix(1))
        qualityStr = ""
    }

    // Validar que la raíz es una letra de nota válida
    guard let firstChar = rootStr.first,
          "ABCDEFG".contains(firstChar) else {
        return nil
    }

    // Obtener MIDI de la fundamental en octava 3
    let rootMidi: Int
    if let override = rootMidiOverrides[rootStr] {
        rootMidi = override
    } else if let noteName = rootNoteNames[rootStr],
              let midi = midiNote(for: noteName) {
        rootMidi = midi
    } else if let midi = midiNote(for: rootStr.lowercased() + "3") {
        rootMidi = midi
    } else {
        return nil
    }

    // Probar sufijos del más largo al más corto para evitar ambigüedades
    // Ordenar las claves por longitud descendente
    let sortedKeys = qualityIntervals.keys.sorted { $0.count > $1.count }

    for quality in sortedKeys {
        if qualityStr == quality {
            let intervals = qualityIntervals[quality]!
            return intervals.map { rootMidi + $0 }
        }
    }

    // Si el sufijo no matchea ninguna calidad conocida → nil
    return nil
}

// MARK: - chord() — constructor de ControlPattern

/// chord("Am") → ControlPattern con haps simultáneos de notas MIDI.
/// Soporta mini-notación: "<Am E Dm G>" alternates por ciclo, "Am E" → secuencia.
/// Cada símbolo se expande a un stack de haps (uno por nota del acorde),
/// todos con el mismo whole/part (simultáneos).
/// Símbolos no reconocidos → silencio (sin crash).
public func chord(_ mini: String) -> ControlPattern {
    // Parsear la mini-notación como Pattern<String> de símbolos de acorde
    let symbolPat: Pattern<String> = MiniNotationCore.parse(mini)

    // Expandir cada símbolo → stack de haps con campo "note"
    return Pattern { span in
        let symbolHaps = symbolPat.query(span)
        var result: [Hap<[String: ControlValue]>] = []

        for hap in symbolHaps {
            // Parsear el símbolo; si es inválido → silencio
            guard let midiNotes = parseChordSymbol(hap.value) else {
                continue
            }

            // Emitir un hap por cada nota del acorde, preservando whole/part
            for midiNote in midiNotes {
                result.append(Hap(
                    whole: hap.whole,
                    part:  hap.part,
                    value: ["note": .double(Double(midiNote))]
                ))
            }
        }

        return result
    }
}

// MARK: - anchor() y voicing() — métodos de ControlPattern

extension Pattern where T == [String: ControlValue] {

    /// anchor("g5") — fija el registro de referencia para voicing().
    /// Inyecta el campo interno "_anchor" con el valor MIDI de la nota dada.
    /// Sin anchor(), voicing() usa c5 (MIDI 72) como ancla por defecto.
    public func anchor(_ note: String) -> ControlPattern {
        guard let anchorMidi = midiNote(for: note) else {
            // Nota inválida: ignorar silenciosamente (devolver self sin ancla)
            return self
        }
        let anchorVal = ControlValue.double(Double(anchorMidi))
        return self.map { dict in
            var out = dict
            out["_anchor"] = anchorVal
            return out
        }
    }

    /// voicing() — re-dispone las notas del acorde de forma compacta cerca del ancla.
    ///
    /// Algoritmo (determinista):
    ///   1. Agrupar los haps por part (TimeSpan) — cada grupo es un "evento de acorde".
    ///   2. Para cada grupo, obtener el ancla (_anchor) o usar 72 (c5).
    ///   3. Extraer los pitch classes (midi % 12) y ordenarlos ascendentemente.
    ///   4. Colocar la primera nota en la octava más cercana al ancla por debajo o igual.
    ///   5. Las siguientes notas: subir de semitono en semitono; si la siguiente pitch class
    ///      es menor que la anterior, sumar 12 (mantener ascendente).
    ///   6. Eliminar el campo "_anchor" del resultado.
    public func voicing() -> ControlPattern {
        return Pattern { span in
            let haps = self.query(span)

            // Agrupar por part (para identificar haps simultáneos del mismo acorde)
            // Usamos begin+end de part como clave de agrupación
            var groups: [TimeSpan: [Hap<[String: ControlValue]>]] = [:]
            for hap in haps {
                let key = hap.part
                groups[key, default: []].append(hap)
            }

            var result: [Hap<[String: ControlValue]>] = []

            for (_, group) in groups {
                guard !group.isEmpty else { continue }

                // Obtener el valor de ancla del primer hap del grupo (todos comparten)
                let anchorMidi: Double
                if let anchorVal = group.first?.value["_anchor"]?.doubleValue {
                    anchorMidi = anchorVal
                } else {
                    anchorMidi = 72.0  // c5 por defecto
                }

                // Extraer pitch classes de los haps con campo "note"
                let noteHaps = group.filter { $0.value["note"] != nil }
                let pitchClasses = noteHaps
                    .compactMap { $0.value["note"]?.doubleValue }
                    .map { Int($0.rounded()) % 12 }
                    .map { ($0 + 12) % 12 }  // asegurar positivo

                if pitchClasses.isEmpty {
                    // Sin notas: pasar los haps sin tocar (quitando _anchor)
                    for hap in group {
                        var newVal = hap.value
                        newVal.removeValue(forKey: "_anchor")
                        result.append(Hap(whole: hap.whole, part: hap.part, value: newVal))
                    }
                    continue
                }

                // Ordenar pitch classes ascendentemente y eliminar duplicados
                let sortedPCs = Array(Set(pitchClasses)).sorted()

                // Calcular la primera nota: pitch class en la octava tal que
                // quede en o por debajo del ancla, lo más cerca posible.
                let firstPC = sortedPCs[0]
                // Octava base: ancla - ((ancla - firstPC) mod 12), ajustada hacia abajo
                let anchorInt = Int(anchorMidi.rounded())
                let anchorPC  = ((anchorInt % 12) + 12) % 12

                // Diferencia desde firstPC hasta anchorPC (circulando hacia arriba)
                let diff = ((anchorPC - firstPC) + 12) % 12
                // La primera nota está diff semitonos por debajo del ancla o en el ancla
                let firstNote = anchorInt - diff

                // Construir las notas voicing: primera + resto ascendente
                var voicedNotes: [Double] = [Double(firstNote)]
                for i in 1..<sortedPCs.count {
                    let prevNote = voicedNotes[i - 1]
                    let pc = sortedPCs[i]
                    let prevPC = ((Int(prevNote.rounded()) % 12) + 12) % 12
                    // Semitones desde prevPC hasta pc (hacia arriba)
                    let semitoneUp = ((pc - prevPC) + 12) % 12
                    let nextNote = prevNote + Double(semitoneUp == 0 ? 12 : semitoneUp)
                    voicedNotes.append(nextNote)
                }

                // Emitir un hap por nota voiciada (same whole/part que el grupo original)
                // Tomar el primer hap como referencia para whole/part
                let ref = group.first!
                for midiVal in voicedNotes {
                    var newVal = ref.value
                    newVal["note"] = .double(midiVal)
                    newVal.removeValue(forKey: "_anchor")
                    result.append(Hap(whole: ref.whole, part: ref.part, value: newVal))
                }
            }

            return result
        }
    }
}
