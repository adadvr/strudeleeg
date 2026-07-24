// ---------------------------------------------------------------------------
// SoundfontManager — carga perezosa de instrumentos GM desde el servidor
// webaudiofontdata de Felix Roos (felixroos.github.io/webaudiofontdata).
//
// Architecture:
//   • Cada instrumento GM es un archivo .js (~500 KB) con formato:
//       console.log('load _tone_XXXX_...');
//       var _tone_XXXX_FluidR3_GM_sf2_file={zones:[{...},...]};
//     donde XXXX = String(format:"%04d", program*10).
//   • Cada zona tiene:
//       - midi: nota MIDI de la zona (no usado para selección — se usa keyRange)
//       - originalPitch: nota raíz en CENTS (dividir /100 para MIDI real)
//       - keyRangeLow/keyRangeHigh: rango de notas que cubre la zona
//       - sampleRate: tasa de muestreo del sample
//       - file: base64 de un MP3 (header = "ID3")
//   • Tabla de los 128 nombres GM Level 1 con prefijo gm_.
//   • resolve(name:midi:) → (buffer, rootMidi) sin bloquear el audio thread.
//   • Cache en disco: ~/Library/Caches/DemoStrudel/soundfonts/
//
// Decisión de integración: los buffers decodificados se insertan en el dict
// buffers del PatternScheduler (via dispatchHap) sin pasar por preloadBuffers
// (que requiere URL local). Se crea el LayerGroup igual que con bancos remotos
// pero usando el buffer ya resuelto. Ver comentarios en PatternScheduler.swift.
// ---------------------------------------------------------------------------

import AVFoundation
import Foundation

// MARK: - Tipos internos

/// Una zona parseada del archivo .js (sin el MP3 decodificado aún).
public struct SoundfontZone {
    public let midi:          Int     // campo midi (referencia; keyRange es el filtro real)
    public let originalPitch: Int     // cents → nota raíz = originalPitch / 100
    public let keyRangeLow:   Int     // nota MIDI mínima que cubre esta zona
    public let keyRangeHigh:  Int     // nota MIDI máxima que cubre esta zona
    public let sampleRate:    Double  // tasa de muestreo del sample original
    public let fileBase64:    String  // base64 del MP3

    /// Nota MIDI raíz del sample (originalPitch en cents ÷ 100).
    public var rootMidi: Int { originalPitch / 100 }
}

// MARK: - SoundfontManager

public final class SoundfontManager {

    // MARK: - Singleton

    public static let shared = SoundfontManager()

    // MARK: - Estado (protegido por serialQueue)

    /// Zonas parseadas por programa GM: program → [SoundfontZone]
    private var zones: [Int: [SoundfontZone]] = [:]
    /// Buffers decodificados por (programa, índice de zona)
    private var decodedBuffers: [String: AVAudioPCMBuffer] = [:]
    /// Descargas en vuelo (key = URL string)
    private var inFlight: Set<String> = []
    /// Programas cuya descarga/parseo ya terminó (aunque result sea vacío)
    private var loadedPrograms: Set<Int> = []
    /// Directorios locales donde buscar sf_{program}.js antes de ir a la red.
    /// Típicamente el bundle de la app (Sources/DemoStrudelApp/Soundfonts/).
    private var localDirs: [URL] = []
    /// Cola serial para todas las mutaciones de estado
    private let serialQueue = DispatchQueue(label: "com.miniengine.soundfont", qos: .userInitiated)

    // MARK: - Directorio de caché

    private static let cacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("DemoStrudel/soundfonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Init

    public init() {}

    // MARK: - API pública

    /// Registra un directorio local (p.ej. el bundle de la app) donde buscar
    /// archivos sf_{program}.js ANTES de ir a la red o a la caché de disco.
    /// Idempotente: si el directorio ya fue registrado, no se agrega de nuevo.
    public func addLocalDirectory(_ url: URL) {
        serialQueue.sync {
            if !localDirs.contains(url) { localDirs.append(url) }
        }
    }

    /// True si el nombre corresponde a un instrumento GM (prefijo "gm_").
    public func isSoundfont(_ name: String) -> Bool {
        // Quitamos sufijo :n si está presente antes de verificar
        let base = name.components(separatedBy: ":").first ?? name
        return base.hasPrefix("gm_")
    }

    /// Prefetch: dispara la descarga de los archivos .js para los nombres dados.
    /// No espera: las descargas ocurren async. No lanza si no hay red.
    public func prefetch(names: [String]) {
        let programs = names.compactMap { program(forName: $0) }
        let unique = Set(programs)
        serialQueue.async { [weak self] in
            guard let self else { return }
            for p in unique {
                guard !self.loadedPrograms.contains(p) else { continue }
                self.enqueueDownload(program: p)
            }
        }
    }

    /// Prefetch con espera acotada (análogo a SampleBankManager.prefetchAndWait).
    /// Ideal para el preescaneo en play(pattern:).
    public func prefetchAndWait(names: [String], timeout: TimeInterval = 0.5) {
        prefetch(names: names)
        let programs = Set(names.compactMap { program(forName: $0) })
        guard !programs.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var allReady = true
            serialQueue.sync {
                for p in programs {
                    if !loadedPrograms.contains(p) { allReady = false; return }
                }
            }
            if allReady { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Resuelve (buffer decodificado, nota MIDI raíz) para un nombre GM y nota MIDI dada.
    /// - Registra el instrumento si no se ha hecho aún (dispara descarga async).
    /// - Elige la zona por keyRange; si ninguna cubre la nota, usa la más cercana.
    /// - Decodifica el MP3 de la zona de forma lazy (base64 → Data → AVAudioPCMBuffer).
    /// - Devuelve nil si el instrumento no está listo aún (no bloquea el audio thread).
    public func resolve(name: String, midi: Int) -> (buffer: AVAudioPCMBuffer, rootMidi: Int)? {
        guard let program = program(forName: name) else { return nil }

        var result: (buffer: AVAudioPCMBuffer, rootMidi: Int)?

        serialQueue.sync {
            // Disparar descarga si hace falta
            if !loadedPrograms.contains(program) {
                enqueueDownload(program: program)
                return  // aún no disponible
            }
            guard let zoneList = zones[program], !zoneList.isEmpty else { return }

            // Elegir zona por keyRange
            let zoneIdx = self.zoneIndex(for: midi, in: zoneList)
            let bufKey  = "\(program):\(zoneIdx)"

            // Buffer ya decodificado
            if let buf = decodedBuffers[bufKey] {
                result = (buf, zoneList[zoneIdx].rootMidi)
                return
            }

            // Decodificar de forma lazy (llamado desde serialQueue: usar global async)
            let zone = zoneList[zoneIdx]
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                if let buf = Self.decodeZone(zone) {
                    self.serialQueue.async {
                        self.decodedBuffers[bufKey] = buf
                    }
                }
            }
            // El buffer no está listo todavía → devolvemos nil
        }

        return result
    }

    // MARK: - Tabla GM Level 1 (128 instrumentos)

    /// Devuelve el número de programa GM (0-127) para un nombre gm_... dado.
    /// Acepta sufijo :n (lo ignora). Devuelve nil si el nombre no es reconocido.
    public func program(forName rawName: String) -> Int? {
        // Quitar sufijo :n
        let name = rawName.components(separatedBy: ":").first ?? rawName
        return Self.gmTable[name]
    }

    // Tabla completa GM Level 1 (nombres públicos, fuente: General MIDI Level 1 spec)
    // Prefijo gm_, espacios → _, minúsculas. Alias de Strudel incluidos.
    static let gmTable: [String: Int] = {
        var t: [String: Int] = [
            // Piano (0-7)
            "gm_acoustic_grand_piano":   0,
            "gm_bright_acoustic_piano":  1,
            "gm_electric_grand_piano":   2,
            "gm_honky_tonk_piano":       3,
            "gm_electric_piano_1":       4,
            "gm_electric_piano_2":       5,
            "gm_harpsichord":            6,
            "gm_clavinet":               7,
            // Chromatic Perc (8-15)
            "gm_celesta":                8,
            "gm_glockenspiel":           9,
            "gm_music_box":              10,
            "gm_vibraphone":             11,
            "gm_marimba":                12,
            "gm_xylophone":              13,
            "gm_tubular_bells":          14,
            "gm_dulcimer":               15,
            // Organ (16-23)
            "gm_drawbar_organ":          16,
            "gm_percussive_organ":       17,
            "gm_rock_organ":             18,
            "gm_church_organ":           19,
            "gm_reed_organ":             20,
            "gm_accordion":              21,
            "gm_harmonica":              22,
            "gm_tango_accordion":        23,
            // Guitar (24-31)
            "gm_acoustic_guitar_nylon":  24,
            "gm_acoustic_guitar_steel":  25,
            "gm_electric_guitar_jazz":   26,
            "gm_electric_guitar_clean":  27,
            "gm_electric_guitar_muted":  28,
            "gm_overdriven_guitar":      29,
            "gm_distortion_guitar":      30,
            "gm_guitar_harmonics":       31,
            // Bass (32-39)
            "gm_acoustic_bass":          32,
            "gm_electric_bass_finger":   33,
            "gm_electric_bass_pick":     34,
            "gm_fretless_bass":          35,
            "gm_slap_bass_1":            36,
            "gm_slap_bass_2":            37,
            "gm_synth_bass_1":           38,
            "gm_synth_bass_2":           39,
            // Strings (40-47)
            "gm_violin":                 40,
            "gm_viola":                  41,
            "gm_cello":                  42,
            "gm_contrabass":             43,
            "gm_tremolo_strings":        44,
            "gm_pizzicato_strings":      45,
            "gm_orchestral_harp":        46,
            "gm_timpani":                47,
            // Ensemble (48-55)
            "gm_string_ensemble_1":      48,
            "gm_string_ensemble_2":      49,
            "gm_synth_strings_1":        50,
            "gm_synth_strings_2":        51,
            "gm_choir_aahs":             52,
            "gm_voice_oohs":             53,
            "gm_synth_choir":            54,
            "gm_orchestra_hit":          55,
            // Brass (56-63)
            "gm_trumpet":                56,
            "gm_trombone":               57,
            "gm_tuba":                   58,
            "gm_muted_trumpet":          59,
            "gm_french_horn":            60,
            "gm_brass_section":          61,
            "gm_synth_brass_1":          62,
            "gm_synth_brass_2":          63,
            // Reed (64-71)
            "gm_soprano_sax":            64,
            "gm_alto_sax":               65,
            "gm_tenor_sax":              66,
            "gm_baritone_sax":           67,
            "gm_oboe":                   68,
            "gm_english_horn":           69,
            "gm_bassoon":                70,
            "gm_clarinet":               71,
            // Pipe (72-79)
            "gm_piccolo":                72,
            "gm_flute":                  73,
            "gm_recorder":               74,
            "gm_pan_flute":              75,
            "gm_blown_bottle":           76,
            "gm_shakuhachi":             77,
            "gm_whistle":                78,
            "gm_ocarina":                79,
            // Synth Lead (80-87)
            "gm_lead_1_square":          80,
            "gm_lead_2_sawtooth":        81,
            "gm_lead_3_calliope":        82,
            "gm_lead_4_chiff":           83,
            "gm_lead_5_charang":         84,
            "gm_lead_6_voice":           85,
            "gm_lead_7_fifths":          86,
            "gm_lead_8_bass_lead":       87,
            // Synth Pad (88-95)
            "gm_pad_1_new_age":          88,
            "gm_pad_2_warm":             89,
            "gm_pad_3_polysynth":        90,
            "gm_pad_4_choir":            91,
            "gm_pad_5_bowed":            92,
            "gm_pad_6_metallic":         93,
            "gm_pad_7_halo":             94,
            "gm_pad_8_sweep":            95,
            // Synth Effects (96-103)
            "gm_fx_1_rain":              96,
            "gm_fx_2_soundtrack":        97,
            "gm_fx_3_crystal":           98,
            "gm_fx_4_atmosphere":        99,
            "gm_fx_5_brightness":        100,
            "gm_fx_6_goblins":           101,
            "gm_fx_7_echoes":            102,
            "gm_fx_8_sci_fi":            103,
            // Ethnic (104-111)
            "gm_sitar":                  104,
            "gm_banjo":                  105,
            "gm_shamisen":               106,
            "gm_koto":                   107,
            "gm_kalimba":                108,
            "gm_bag_pipe":               109,
            "gm_fiddle":                 110,
            "gm_shanai":                 111,
            // Percussive (112-119)
            "gm_tinkle_bell":            112,
            "gm_agogo":                  113,
            "gm_steel_drums":            114,
            "gm_woodblock":              115,
            "gm_taiko_drum":             116,
            "gm_melodic_tom":            117,
            "gm_synth_drum":             118,
            "gm_reverse_cymbal":         119,
            // Sound Effects (120-127)
            "gm_guitar_fret_noise":      120,
            "gm_breath_noise":           121,
            "gm_seashore":               122,
            "gm_bird_tweet":             123,
            "gm_telephone_ring":         124,
            "gm_helicopter":             125,
            "gm_applause":               126,
            "gm_gunshot":                127,
        ]
        // Alias de Strudel (nombres cortos usados en la práctica)
        t["gm_epiano1"] = 4   // electric piano 1
        t["gm_epiano2"] = 5   // electric piano 2
        t["gm_piano"]   = 0   // alias corto
        t["gm_bass"]    = 32  // acoustic bass
        t["gm_strings"] = 48  // string ensemble 1
        t["gm_organ"]   = 19  // church organ
        t["gm_guitar"]  = 25  // acoustic guitar steel
        return t
    }()

    // MARK: - Selección de zona

    /// Índice de la zona que mejor cubre la nota MIDI dada.
    /// Primero busca por keyRange; si ninguna cubre, usa la de menor distancia al centro.
    public func zoneIndex(for midi: Int, in zoneList: [SoundfontZone]) -> Int {
        // Búsqueda exacta por keyRange
        for (i, z) in zoneList.enumerated() {
            if midi >= z.keyRangeLow && midi <= z.keyRangeHigh { return i }
        }
        // Fallback: zona cuyo centro sea más cercano a la nota pedida
        var bestIdx  = 0
        var bestDist = Int.max
        for (i, z) in zoneList.enumerated() {
            let center = (z.keyRangeLow + z.keyRangeHigh) / 2
            let dist   = abs(center - midi)
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        return bestIdx
    }

    // MARK: - Descarga y parseo (interno, puede llamarse fuera de serialQueue)

    private func enqueueDownload(program: Int) {
        // Llamado desde dentro de serialQueue.async — no volvemos a entrar
        guard !loadedPrograms.contains(program),
              !inFlight.contains("\(program)") else { return }
        inFlight.insert("\(program)")

        let urlString = Self.jsURL(forProgram: program)
        let cacheFile = Self.cacheDir.appendingPathComponent("sf_\(program).js")

        // Snapshot de directorios locales para leerlo fuera de la serialQueue
        // (evita deadlock: serialQueue.sync desde dentro de serialQueue).
        let localDirsSnapshot: [URL] = localDirs

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            // ── 1. Directorios locales (bundle) ─────────────────────────────
            // Buscamos sf_{program}.js en cada directorio registrado antes que
            // en la caché de disco y antes de ir a la red.
            for dir in localDirsSnapshot {
                let localFile = dir.appendingPathComponent("sf_\(program).js")
                guard FileManager.default.fileExists(atPath: localFile.path),
                      let js = try? String(contentsOf: localFile, encoding: .utf8)
                else { continue }

                let parsed = Self.parseZones(js)
                self.serialQueue.async {
                    self.zones[program] = parsed
                    self.loadedPrograms.insert(program)
                    self.inFlight.remove("\(program)")
                    print("[SoundfontManager] Cargado local (bundle): programa \(program) (\(parsed.count) zonas)")
                }
                return
            }

            // ── 2. Caché de disco: si el archivo ya existe, usarlo ──────────
            if FileManager.default.fileExists(atPath: cacheFile.path),
               let js = try? String(contentsOf: cacheFile, encoding: .utf8) {
                let parsed = Self.parseZones(js)
                self.serialQueue.async {
                    self.zones[program] = parsed
                    self.loadedPrograms.insert(program)
                    self.inFlight.remove("\(program)")
                    print("[SoundfontManager] Cargado desde caché: programa \(program) (\(parsed.count) zonas)")
                }
                return
            }

            // Descarga HTTP
            guard let url = URL(string: urlString) else {
                self.serialQueue.async {
                    self.loadedPrograms.insert(program)
                    self.inFlight.remove("\(program)")
                }
                return
            }
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                guard let self else { return }
                if let data, error == nil,
                   let js = String(data: data, encoding: .utf8) {
                    // Guardar en disco
                    try? data.write(to: cacheFile, options: .atomic)
                    let parsed = Self.parseZones(js)
                    self.serialQueue.async {
                        self.zones[program] = parsed
                        self.loadedPrograms.insert(program)
                        self.inFlight.remove("\(program)")
                        print("[SoundfontManager] Descargado: programa \(program) (\(parsed.count) zonas) desde \(urlString)")
                    }
                } else {
                    print("[SoundfontManager] Error descargando programa \(program): \(error?.localizedDescription ?? "?")")
                    self.serialQueue.async {
                        self.loadedPrograms.insert(program)   // marcamos como "intentado" para no re-intentar en loop
                        self.inFlight.remove("\(program)")
                    }
                }
            }
            task.resume()
        }
    }

    // MARK: - URL de instrumento GM

    /// Construye la URL del .js para un programa GM (0-127).
    /// Formato: https://felixroos.github.io/webaudiofontdata/sound/{XXXX}_FluidR3_GM_sf2_file.js
    /// donde XXXX = String(format:"%04d", program * 10).
    static func jsURL(forProgram program: Int) -> String {
        let id = String(format: "%04d", program * 10)
        return "https://felixroos.github.io/webaudiofontdata/sound/\(id)_FluidR3_GM_sf2_file.js"
    }

    // MARK: - Parser de zonas (expuesto para tests)

    /// Parsea el contenido de un archivo .js de webaudiofontdata y extrae las zonas.
    ///
    /// Estrategia robusta para el formato no-JSON:
    ///   1. Eliminar la línea console.log(...)
    ///   2. Extraer el contenido del array zones:[...]
    ///   3. Escanear cada zona individualmente con regex para los campos numéricos
    ///      y el campo file:'...' (base64 que puede ser muy largo).
    ///
    /// El parser es tolerante: si una zona falla, se salta sin crashear.
    public static func parseZones(_ js: String) -> [SoundfontZone] {
        // Paso 1: quitar la línea console.log
        let noLog = js.replacingOccurrences(
            of: #"console\.log\([^)]*\);\s*"#,
            with: "",
            options: .regularExpression
        )

        // Paso 2: extraer el contenido del bloque zones:[...]
        // Buscamos "zones:[" y el corchete balanceado de cierre
        guard let zonesStart = noLog.range(of: "zones:[") else { return [] }
        let afterBracket = noLog[zonesStart.upperBound...]

        // Balancear corchetes para encontrar el fin del array
        var depth = 1
        var zonesEndIdx = afterBracket.startIndex
        for idx in afterBracket.indices {
            let c = afterBracket[idx]
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { zonesEndIdx = idx; break }
            }
        }
        let zonesContent = String(afterBracket[..<zonesEndIdx])

        // Paso 3: dividir en zonas individuales (cada zona es un bloque {...})
        return extractZoneBlocks(from: zonesContent)
    }

    /// Divide el contenido del array zones en bloques individuales {...} y parsea cada uno.
    private static func extractZoneBlocks(from content: String) -> [SoundfontZone] {
        var zones: [SoundfontZone] = []
        var depth = 0
        var blockStart: String.Index? = nil
        let chars = content

        for idx in chars.indices {
            let c = chars[idx]
            if c == "{" {
                if depth == 0 { blockStart = idx }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let start = blockStart {
                    let block = String(chars[start...idx])
                    if let zone = parseZoneBlock(block) {
                        zones.append(zone)
                    }
                    blockStart = nil
                }
            }
        }
        return zones
    }

    /// Parsea un bloque de zona individual: { midi:4, originalPitch:2400, ..., file:'base64...' }
    /// Usa regex para cada campo numérico y escaneo de cadena para file.
    private static func parseZoneBlock(_ block: String) -> SoundfontZone? {
        // Extraer campos numéricos con regex tolerante (sin comillas en keys)
        guard let midi          = extractInt(from: block, key: "midi"),
              let originalPitch = extractInt(from: block, key: "originalPitch"),
              let keyRangeLow   = extractInt(from: block, key: "keyRangeLow"),
              let keyRangeHigh  = extractInt(from: block, key: "keyRangeHigh"),
              let sampleRate    = extractDouble(from: block, key: "sampleRate")
        else { return nil }

        // Extraer el campo file:'...' que contiene el base64 (puede ser muy largo)
        let fileBase64 = extractFileField(from: block)
        guard !fileBase64.isEmpty else { return nil }

        return SoundfontZone(
            midi:          midi,
            originalPitch: originalPitch,
            keyRangeLow:   keyRangeLow,
            keyRangeHigh:  keyRangeHigh,
            sampleRate:    sampleRate,
            fileBase64:    fileBase64
        )
    }

    /// Extrae un entero de un bloque JS dada la key (sin comillas).
    /// Tolerante a espacios y comas. Ej: "keyRangeLow:0," → 0.
    static func extractInt(from block: String, key: String) -> Int? {
        // Patrón: key seguida de : y dígitos opcionales con signo
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: key) + #"\s*:\s*(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: block,
                range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else { return nil }
        return Int(block[range])
    }

    /// Extrae un Double de un bloque JS.
    static func extractDouble(from block: String, key: String) -> Double? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: key) + #"\s*:\s*(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: block,
                range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else { return nil }
        return Double(block[range])
    }

    /// Extrae el contenido del campo file:'...' del bloque de zona.
    /// El base64 puede contener +/= y ser muy largo (>1MB), por lo que NO usamos regex
    /// sino búsqueda directa de 'file:' con comilla simple o doble.
    static func extractFileField(from block: String) -> String {
        // Buscamos 'file:' seguido de una comilla (simple o doble)
        for prefix in ["file:'", #"file:""#] {
            guard let startRange = block.range(of: prefix) else { continue }
            let quoteChar: Character = prefix.hasSuffix("'") ? "'" : "\""
            let afterQuote = block[startRange.upperBound...]
            // Buscar la comilla de cierre (la base64 no contiene comillas)
            if let endIdx = afterQuote.firstIndex(of: quoteChar) {
                return String(afterQuote[..<endIdx])
            }
        }
        return ""
    }

    // MARK: - Decodificación de zona (base64 → MP3 → AVAudioPCMBuffer)

    /// Decodifica una zona: base64 → Data (MP3) → archivo temporal → AVAudioFile → PCMBuffer.
    /// Borra el archivo temporal al terminar. Devuelve nil si algo falla.
    static func decodeZone(_ zone: SoundfontZone) -> AVAudioPCMBuffer? {
        // Limpiar el base64 (puede tener saltos de línea o espacios)
        let cleanB64 = zone.fileBase64
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ",  with: "")

        guard let mp3Data = Data(base64Encoded: cleanB64, options: .ignoreUnknownCharacters) else {
            print("[SoundfontManager] Base64 inválido para zona (originalPitch=\(zone.originalPitch))")
            return nil
        }

        // Escribir a archivo temporal .mp3 (AVAudioFile no acepta Data directamente)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf_\(UUID().uuidString).mp3")
        do {
            try mp3Data.write(to: tmpURL, options: .atomic)
        } catch {
            print("[SoundfontManager] No se pudo escribir MP3 temporal: \(error)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let file = try AVAudioFile(forReading: tmpURL)
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return nil }
            try file.read(into: buf)
            // Normalizar al formato canónico del scheduler (float32, stereo, 44.1 kHz)
            return PatternScheduler.normalizedBuffer(buf)
        } catch {
            print("[SoundfontManager] No se pudo decodificar MP3 de zona: \(error)")
            return nil
        }
    }

    // MARK: - Clear (para tests)

    public func clear() {
        serialQueue.sync {
            zones = [:]
            decodedBuffers = [:]
            inFlight = []
            loadedPrograms = []
            localDirs = []
        }
    }
}
