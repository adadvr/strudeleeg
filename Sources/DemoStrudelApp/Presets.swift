import Foundation

// ---------------------------------------------------------------------------
// Presets.swift — Templates de canciones para el select box de la UI.
//
// - Templates built-in (electrónica + meditación/relajación, 1+ min cada uno).
//   Usan solo funciones/samples/patterns soportados por el Mini Engine y que
//   además existen en Strudel real (para el A/B). Instrumentos GM elegidos del
//   set bundleado (offline) — ver scripts/fetch_soundfonts.sh.
// - Templates de usuario: se guardan como archivos .strudel en
//   Application Support/DemoStrudel/Presets y se listan en el mismo dropdown.
// ---------------------------------------------------------------------------

public struct SongPreset: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let code: String
    public let isBuiltIn: Bool
}

enum PresetStore {

    // MARK: - Directorio de templates de usuario

    /// ~/Library/Application Support/DemoStrudel/Presets
    static var userDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DemoStrudel/Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Carga / guardado

    /// Todos los presets: built-in primero, luego los de usuario (orden alfabético).
    static func all() -> [SongPreset] {
        builtIns + loadUser()
    }

    /// Lee los .strudel del directorio de usuario. El nombre = nombre de archivo sin extensión.
    static func loadUser() -> [SongPreset] {
        let dir = userDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "strudel" }
            .compactMap { url -> SongPreset? in
                guard let code = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return SongPreset(name: url.deletingPathExtension().lastPathComponent,
                                  code: code, isBuiltIn: false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Guarda un template de usuario. Devuelve el preset creado. Sobrescribe si ya existe.
    @discardableResult
    static func save(name rawName: String, code: String) throws -> SongPreset {
        let name = sanitize(rawName)
        let url = userDir.appendingPathComponent("\(name).strudel")
        try code.write(to: url, atomically: true, encoding: .utf8)
        return SongPreset(name: name, code: code, isBuiltIn: false)
    }

    /// Nombre de archivo seguro (sin / ni caracteres problemáticos).
    private static func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
                             .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "template" : cleaned
    }

    // MARK: - Templates built-in

    static let builtIns: [SongPreset] = [
        SongPreset(name: "① Deriva Alfa (ambient techno)", code: derivaAlfa, isBuiltIn: true),
        SongPreset(name: "② Respiración (meditación drone)", code: respiracion, isBuiltIn: true),
        SongPreset(name: "③ Circadiano (downtempo melódico)", code: circadiano, isBuiltIn: true),
    ]

    // ---------------------------------------------------------------------
    // Template ① — Deriva Alfa
    // Ambient techno lento y relajante. ~64s de evolución antes de repetir.
    // cps 0.25 → 1 ciclo = 4s.
    // ---------------------------------------------------------------------
    static let derivaAlfa = """
    samples('github:tidalcycles/dirt-samples')
    setcps(0.25)

    stack(
      // Viento de fondo, todo el tema
      s("wind").gain(0.12).lpf(800).room(0.6).slow(8).pan(0.3),

      // Pájaros ocasionales
      s("<birds ~ ~ ~ birds ~ ~ ~ ~ ~ birds ~ ~ ~ ~ ~>")
        .gain(0.14).room(0.6).pan(0.7).speed(0.9),

      // Pad armónico con voicing; el filtro respira con una señal continua
      chord("<Am7 Fmaj7 Cmaj7 G>").voicing().anchor("c4")
        .s("sawtooth")
        .attack(1.5).decay(1).sustain(0.6).release(2.5)
        .lpf(sine.range(400, 1400).slow(16)).resonance(2)
        .gain(0.18).room(0.7).pan(0.4),

      // Kick suave que entra a los ~32s (ciclo 8)
      s("<~!8 [bd ~ ~ ~ bd ~ ~ ~]!12>").gain(0.7).decay(0.35).lpf(1200),

      // Hi-hats tenues, entran después
      s("<~!10 [hh ~ hh ~ hh ~ hh ~]!10>").gain(0.2).decay(0.12).pan(0.6).hpf(4000),

      // Melodía de piano eléctrico GM (bundleado), frases espaciadas
      note("<~!4 [c5 ~ e5 ~] [g5 ~ ~ e5] [a5 ~ g5 ~] [e5 ~ ~ ~] [f5 ~ a5 ~] [g5 ~ e5 ~] [c5 ~ ~ ~] ~!4 [e5 ~ g5 a5] [g5 ~ e5 ~] [d5 ~ ~ c5] [c5 ~ ~ ~]>")
        .s("gm_electric_piano_1")
        .clip(0.9).gain(0.4).room(0.5).pan(0.55)
        .delay(0.2).delaytime(0.75).delayfeedback(0.3)
    )
    """

    // ---------------------------------------------------------------------
    // Template ② — Respiración
    // Meditación / drone. Muy lento. ~120s de evolución. cps 0.2 → ciclo = 5s.
    // ---------------------------------------------------------------------
    static let respiracion = """
    samples('github:tidalcycles/dirt-samples')
    setcps(0.2)

    stack(
      // Drone base: pad GM cálido, muy lento, filtro que respira
      chord("<Cmaj7 Cmaj7 Am7 Am7>").voicing().anchor("c3")
        .s("gm_pad_2_warm")
        .attack(3).decay(2).sustain(0.7).release(4)
        .lpf(sine.range(300, 900).slow(24)).gain(0.28).room(0.85),

      // Latido tipo corazón, muy suave
      s("<[bd ~ ~ ~ ~ ~ bd ~ ~ ~ ~ ~ ~ ~ ~ ~]>").gain(0.4).lpf(500).decay(0.5),

      // Vibráfono GM (bundleado) — campanadas meditativas espaciadas
      note("<c6 ~ ~ ~ ~ ~ ~ ~ g5 ~ ~ ~ ~ ~ ~ ~ e6 ~ ~ ~ ~ ~ ~ ~ a5 ~ ~ ~ ~ ~ ~ ~>")
        .s("gm_vibraphone")
        .attack(0.01).release(4).gain(0.22).room(0.9).pan(0.5)
        .delay(0.3).delaytime(1.5).delayfeedback(0.4),

      // Viento y aire
      s("wind").gain(0.14).lpf(700).room(0.7).slow(10).pan(0.4)
    )
    """

    // ---------------------------------------------------------------------
    // Template ③ — Circadiano
    // Electrónica melódica relajada (downtempo). ~64s. cps 0.25 → ciclo = 4s.
    // ---------------------------------------------------------------------
    static let circadiano = """
    samples('github:tidalcycles/dirt-samples')
    setcps(0.25)

    stack(
      // Beat downtempo, entra escalonado
      s("<~!2 [bd ~ ~ ~ bd ~ ~ ~]!14>").gain(0.75).decay(0.35),
      s("<~!4 [~ ~ ~ ~ cp ~ ~ ~]!12>").gain(0.4).room(0.3),
      s("<~!3 [hh ~ hh ~ hh ~ hh ~]!13>").gain(0.22).decay(0.1).pan(0.6).hpf(5000),

      // Bajo acid (sawtooth con envolvente de filtro)
      note("<a1 a1 f1 f1 c2 c2 g1 g1>").s("sawtooth")
        .attack(0.01).decay(0.3).sustain(0.3).release(0.15)
        .lpf(sine.range(400, 1100).slow(8)).resonance(3).lpenv(1.5).gain(0.4),

      // Acordes de cuerdas GM con voicing
      chord("<Am F C G>").voicing().anchor("c4")
        .s("gm_string_ensemble_1")
        .attack(0.8).release(1.5).lpf(2000).gain(0.22).room(0.5).pan(0.35),

      // Arpegio de piano eléctrico GM
      note("<[a4 c5 e5]*2 [f4 a4 c5]*2 [c5 e5 g5]*2 [g4 b4 d5]*2>")
        .s("gm_electric_piano_1").clip(0.6)
        .lpf(2500).gain(0.32).room(0.4).pan(0.55)
        .delay(0.25).delaytime(0.5).delayfeedback(0.3),

      // Melodía lead relajada (segunda mitad)
      note("<~!6 [e5 ~ g5 ~] [a5 ~ ~ g5] [e5 ~ d5 ~] [c5 ~ ~ ~] ~!2 [g5 ~ a5 c6] [b5 ~ g5 ~] [a5 ~ ~ ~] [e5 ~ ~ ~]>")
        .s("gm_electric_piano_2").clip(0.9)
        .lpf(3000).gain(0.3).room(0.4).pan(0.5)
        .delay(0.2).delaytime(0.75).delayfeedback(0.35)
    )
    """
}
