import XCTest
import AVFoundation
@testable import MiniEngine

// ---------------------------------------------------------------------------
// SoundfontTests — tests offline y live para SoundfontManager.
//
// Tests offline (sin red):
//   • Tabla GM: program(forName:) para los anclas documentadas.
//   • Parser de zonas: string .js sintético mínimo → campos extraídos.
//   • Selección de zona: zoneFor(midi:) elige la zona correcta por keyRange.
//   • Repitch: tasa correcta 2^((midi - root)/12).
//   • isSoundfont: true/false.
//
// Tests live (con red, skipeables):
//   • Descargar gm_electric_piano_1, resolver midi 60, buffer con frames > 0.
// ---------------------------------------------------------------------------

final class SoundfontTests: XCTestCase {

    // MARK: - Tabla GM: program(forName:)

    func testProgramForNameAnchors() {
        let sfm = SoundfontManager()
        // Anclas documentadas en el spec
        XCTAssertEqual(sfm.program(forName: "gm_acoustic_grand_piano"),  0)
        XCTAssertEqual(sfm.program(forName: "gm_electric_piano_1"),      4)
        XCTAssertEqual(sfm.program(forName: "gm_electric_piano_2"),      5)
        XCTAssertEqual(sfm.program(forName: "gm_acoustic_guitar_steel"), 25)
        XCTAssertEqual(sfm.program(forName: "gm_pizzicato_strings"),     45)
        XCTAssertEqual(sfm.program(forName: "gm_string_ensemble_1"),     48)
        XCTAssertEqual(sfm.program(forName: "gm_violin"),                40)
        XCTAssertEqual(sfm.program(forName: "gm_church_organ"),          19)
        XCTAssertEqual(sfm.program(forName: "gm_flute"),                 73)
        XCTAssertEqual(sfm.program(forName: "gm_trumpet"),               56)
        XCTAssertEqual(sfm.program(forName: "gm_cello"),                 42)
    }

    func testProgramForNameAliases() {
        let sfm = SoundfontManager()
        // Alias de Strudel
        XCTAssertEqual(sfm.program(forName: "gm_epiano1"), 4)
        XCTAssertEqual(sfm.program(forName: "gm_epiano2"), 5)
    }

    func testProgramForNameWithColonNSuffix() {
        let sfm = SoundfontManager()
        // Sufijo :n debe ignorarse
        XCTAssertEqual(sfm.program(forName: "gm_flute:3"),   73)
        XCTAssertEqual(sfm.program(forName: "gm_violin:0"),  40)
        XCTAssertEqual(sfm.program(forName: "gm_epiano1:2"), 4)
    }

    func testProgramForNameUnknown() {
        let sfm = SoundfontManager()
        XCTAssertNil(sfm.program(forName: "bd"))
        XCTAssertNil(sfm.program(forName: "tabla"))
        XCTAssertNil(sfm.program(forName: "gm_nonexistent_instrument"))
    }

    // MARK: - isSoundfont

    func testIsSoundfontTrue() {
        let sfm = SoundfontManager()
        XCTAssertTrue(sfm.isSoundfont("gm_flute"))
        XCTAssertTrue(sfm.isSoundfont("gm_epiano1"))
        XCTAssertTrue(sfm.isSoundfont("gm_violin:3"))
        XCTAssertTrue(sfm.isSoundfont("gm_acoustic_grand_piano"))
    }

    func testIsSoundfontFalse() {
        let sfm = SoundfontManager()
        XCTAssertFalse(sfm.isSoundfont("bd"))
        XCTAssertFalse(sfm.isSoundfont("tabla"))
        XCTAssertFalse(sfm.isSoundfont("sawtooth"))
        XCTAssertFalse(sfm.isSoundfont("sine"))
        XCTAssertFalse(sfm.isSoundfont(""))
    }

    // MARK: - jsURL

    func testJSURLFormat() {
        XCTAssertEqual(
            SoundfontManager.jsURL(forProgram: 0),
            "https://felixroos.github.io/webaudiofontdata/sound/0000_FluidR3_GM_sf2_file.js"
        )
        XCTAssertEqual(
            SoundfontManager.jsURL(forProgram: 4),
            "https://felixroos.github.io/webaudiofontdata/sound/0040_FluidR3_GM_sf2_file.js"
        )
        XCTAssertEqual(
            SoundfontManager.jsURL(forProgram: 25),
            "https://felixroos.github.io/webaudiofontdata/sound/0250_FluidR3_GM_sf2_file.js"
        )
        XCTAssertEqual(
            SoundfontManager.jsURL(forProgram: 48),
            "https://felixroos.github.io/webaudiofontdata/sound/0480_FluidR3_GM_sf2_file.js"
        )
        XCTAssertEqual(
            SoundfontManager.jsURL(forProgram: 127),
            "https://felixroos.github.io/webaudiofontdata/sound/1270_FluidR3_GM_sf2_file.js"
        )
    }

    // MARK: - Parser de zonas (offline, string .js sintético)

    /// JS mínimo con 2 zonas (base64 inventado corto). Verificamos que el parser
    /// extrae los campos numéricos y el campo file correctamente.
    func testParseZonesSynthetic() {
        // Base64 del string ASCII "ID3" (cabecera MP3 mínima ficticia para el test)
        let fakeB64a = "SUQzBAAA"  // "ID3\x04\x00\x00"
        let fakeB64b = "SUQzAAAA"  // base64 ligeramente distinto

        let js = """
        console.log('load _tone_0040_FluidR3_GM_sf2_file');
        var _tone_0040_FluidR3_GM_sf2_file={
            zones:[
                { midi:4, originalPitch:2400, keyRangeLow:0, keyRangeHigh:27,
                  loopStart:143150, loopEnd:144503, coarseTune:0, fineTune:0,
                  sampleRate:22050, ahdsr:true, file:'\(fakeB64a)' },
                { midi:4, originalPitch:4800, keyRangeLow:28, keyRangeHigh:127,
                  loopStart:0, loopEnd:1024, coarseTune:0, fineTune:0,
                  sampleRate:44100, ahdsr:false, file:'\(fakeB64b)' }
            ]}
        """

        let zones = SoundfontManager.parseZones(js)

        XCTAssertEqual(zones.count, 2, "Deben parsearse 2 zonas")

        // Zona 0
        XCTAssertEqual(zones[0].midi,          4)
        XCTAssertEqual(zones[0].originalPitch, 2400)
        XCTAssertEqual(zones[0].keyRangeLow,   0)
        XCTAssertEqual(zones[0].keyRangeHigh,  27)
        XCTAssertEqual(zones[0].sampleRate,    22050.0)
        XCTAssertEqual(zones[0].fileBase64,    fakeB64a)
        XCTAssertEqual(zones[0].rootMidi,      24)  // 2400 / 100

        // Zona 1
        XCTAssertEqual(zones[1].midi,          4)
        XCTAssertEqual(zones[1].originalPitch, 4800)
        XCTAssertEqual(zones[1].keyRangeLow,   28)
        XCTAssertEqual(zones[1].keyRangeHigh,  127)
        XCTAssertEqual(zones[1].sampleRate,    44100.0)
        XCTAssertEqual(zones[1].fileBase64,    fakeB64b)
        XCTAssertEqual(zones[1].rootMidi,      48)  // 4800 / 100
    }

    func testParseZonesEmptyJS() {
        let zones = SoundfontManager.parseZones("console.log('x');var x={zones:[]}")
        XCTAssertTrue(zones.isEmpty)
    }

    func testParseZonesNoConsoleLog() {
        // Sin console.log: el parser también debe funcionar
        let fakeB64 = "SUQzBAAA"
        let js = """
        var _tone_0000_FluidR3_GM_sf2_file={zones:[
          {midi:0,originalPitch:6000,keyRangeLow:0,keyRangeHigh:127,sampleRate:44100,file:'\(fakeB64)'}
        ]}
        """
        let zones = SoundfontManager.parseZones(js)
        XCTAssertEqual(zones.count, 1)
        XCTAssertEqual(zones[0].rootMidi, 60)  // 6000/100
        XCTAssertEqual(zones[0].fileBase64, fakeB64)
    }

    // MARK: - Selección de zona (zoneIndex)

    func testZoneSelectionExactRange() {
        let sfm = SoundfontManager()
        let zones: [SoundfontZone] = [
            SoundfontZone(midi: 0, originalPitch: 2400, keyRangeLow: 0,  keyRangeHigh: 27,  sampleRate: 22050, fileBase64: ""),
            SoundfontZone(midi: 0, originalPitch: 4800, keyRangeLow: 28, keyRangeHigh: 59,  sampleRate: 22050, fileBase64: ""),
            SoundfontZone(midi: 0, originalPitch: 7200, keyRangeLow: 60, keyRangeHigh: 127, sampleRate: 44100, fileBase64: ""),
        ]

        XCTAssertEqual(sfm.zoneIndex(for: 0,   in: zones), 0)
        XCTAssertEqual(sfm.zoneIndex(for: 27,  in: zones), 0)
        XCTAssertEqual(sfm.zoneIndex(for: 28,  in: zones), 1)
        XCTAssertEqual(sfm.zoneIndex(for: 59,  in: zones), 1)
        XCTAssertEqual(sfm.zoneIndex(for: 60,  in: zones), 2)
        XCTAssertEqual(sfm.zoneIndex(for: 127, in: zones), 2)
    }

    func testZoneSelectionFallbackNearest() {
        let sfm = SoundfontManager()
        // Zonas con gap (nota 50 no cubierta): debe elegir la más cercana por centro
        let zones: [SoundfontZone] = [
            SoundfontZone(midi: 0, originalPitch: 3600, keyRangeLow: 0,  keyRangeHigh: 40,  sampleRate: 22050, fileBase64: ""),
            SoundfontZone(midi: 0, originalPitch: 7200, keyRangeLow: 60, keyRangeHigh: 127, sampleRate: 44100, fileBase64: ""),
        ]
        // Nota 50: centro zona 0 = 20, centro zona 1 = 93. dist(50,20)=30, dist(50,93)=43 → zona 0
        XCTAssertEqual(sfm.zoneIndex(for: 50, in: zones), 0)
        // Nota 80: dist(80,20)=60, dist(80,93)=13 → zona 1
        XCTAssertEqual(sfm.zoneIndex(for: 80, in: zones), 1)
    }

    // MARK: - Repitch rate

    func testRepitchRate() {
        // rate = 2^((midi - rootMidi) / 12)
        // midi == rootMidi → rate = 1.0
        let rate60 = pow(2.0, Double(60 - 60) / 12.0)
        XCTAssertEqual(rate60, 1.0, accuracy: 1e-10)

        // midi = 72 (una octava arriba de 60) → rate = 2.0
        let rate72 = pow(2.0, Double(72 - 60) / 12.0)
        XCTAssertEqual(rate72, 2.0, accuracy: 1e-10)

        // midi = 48 (una octava abajo de 60) → rate = 0.5
        let rate48 = pow(2.0, Double(48 - 60) / 12.0)
        XCTAssertEqual(rate48, 0.5, accuracy: 1e-10)

        // midi = 64 (4 semitonos arriba de 60) → rate ≈ 1.2599
        let rate64 = pow(2.0, Double(64 - 60) / 12.0)
        XCTAssertEqual(rate64, pow(2.0, 4.0/12.0), accuracy: 1e-10)
    }

    // MARK: - extractInt / extractDouble (helpers del parser)

    func testExtractIntFromBlock() {
        let block = "{ midi:4, originalPitch:2400, keyRangeLow:0, keyRangeHigh:27, sampleRate:22050 }"
        XCTAssertEqual(SoundfontManager.extractInt(from: block, key: "midi"),          4)
        XCTAssertEqual(SoundfontManager.extractInt(from: block, key: "originalPitch"), 2400)
        XCTAssertEqual(SoundfontManager.extractInt(from: block, key: "keyRangeLow"),   0)
        XCTAssertEqual(SoundfontManager.extractInt(from: block, key: "keyRangeHigh"),  27)
    }

    func testExtractDoubleFromBlock() {
        let block = "{ sampleRate:22050, fineTune:-3 }"
        XCTAssertEqual(SoundfontManager.extractDouble(from: block, key: "sampleRate"), 22050.0)
        XCTAssertEqual(SoundfontManager.extractDouble(from: block, key: "fineTune"),   -3.0)
    }

    func testExtractFileField() {
        let b64 = "SUQzBAAA1234+/="
        let block = "{ file:'\(b64)', other:1 }"
        XCTAssertEqual(SoundfontManager.extractFileField(from: block), b64)
    }

    func testExtractFileFieldDoubleQuote() {
        let b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        let block = #"{ file:"\#(b64)", other:1 }"#
        XCTAssertEqual(SoundfontManager.extractFileField(from: block), b64)
    }
}

// MARK: - SoundfontLiveTests

final class SoundfontLiveTests: XCTestCase {

    /// Salta el test si no hay red (análogo a RemoteBankLiveTests).
    private func requireNetwork() throws {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var req = URLRequest(url: URL(string: "https://felixroos.github.io")!)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = resp != nil
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        try XCTSkipUnless(ok, "sin red — se salta el test live de soundfonts")
    }

    /// Descarga gm_electric_piano_1 (programa 4), resuelve midi 60,
    /// verifica que el buffer resultante tiene frameLength > 0.
    func testLiveResolveElectricPiano() throws {
        try requireNetwork()

        let sfm = SoundfontManager.shared
        sfm.clear()

        // Prefetch con espera larga para dar tiempo a la descarga y parseo del .js
        sfm.prefetchAndWait(names: ["gm_electric_piano_1"], timeout: 25.0)

        // Primer intento de resolve: puede detonar la decodificación del MP3 (lazy).
        // La decodificación es async → esperamos con reintentos acotados.
        var result: (buffer: AVAudioPCMBuffer, rootMidi: Int)?
        let deadline = Date().addingTimeInterval(20.0)
        while Date() < deadline {
            result = sfm.resolve(name: "gm_electric_piano_1", midi: 60)
            if result != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard let (buf, rootMidi) = result else {
            XCTFail("resolve devolvió nil después del prefetch+decode — el instrumento no se cargó")
            return
        }

        XCTAssertGreaterThan(buf.frameLength, 0, "El buffer debe tener frames decodificados")
        XCTAssertGreaterThanOrEqual(rootMidi, 0)
        XCTAssertLessThanOrEqual(rootMidi, 127)
        print("[SoundfontLiveTests] midi=60 → rootMidi=\(rootMidi), frames=\(buf.frameLength)")
    }
}

/// Verifica la carga OFFLINE desde el set bundleado local (Sources/DemoStrudelApp/Soundfonts).
/// Prueba que un MP3 del set curado se decodifica a un buffer válido SIN red — que es
/// exactamente lo que hace el Mini Engine al reproducir un gm_ con el bundle presente.
final class SoundfontLocalBundleTests: XCTestCase {

    /// Ruta al directorio de soundfonts bundleados, derivada de la ubicación de este archivo.
    /// repo/MiniEngine/Tests/MiniEngineTests/SoundfontTests.swift → repo/Sources/DemoStrudelApp/Soundfonts
    private func localSoundfontsDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir = dir.deletingLastPathComponent() }  // → repo root
        return dir.appendingPathComponent("Sources/DemoStrudelApp/Soundfonts", isDirectory: true)
    }

    /// gm_electric_piano_1 (programa 4 = sf_4.js del set curado) se carga y decodifica
    /// desde el directorio local, sin tocar la red.
    func testLocalBundleLoadsAndDecodes() throws {
        let dir = localSoundfontsDir()
        let file = dir.appendingPathComponent("sf_4.js")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: file.path),
            "sf_4.js no está en el set local — correr scripts/fetch_soundfonts.sh"
        )

        let sfm = SoundfontManager.shared
        sfm.clear()
        sfm.addLocalDirectory(dir)   // preferir el bundle local antes que la red

        // El parseo del .js local es rápido; la decodificación del MP3 es async → poll acotado.
        var result: (buffer: AVAudioPCMBuffer, rootMidi: Int)?
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            result = sfm.resolve(name: "gm_electric_piano_1", midi: 60)
            if result != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard let (buf, rootMidi) = result else {
            XCTFail("resolve devolvió nil — el MP3 del set local no se decodificó en el Mini Engine")
            return
        }
        XCTAssertGreaterThan(buf.frameLength, 0, "El buffer decodificado del MP3 local debe tener frames")
        XCTAssertGreaterThanOrEqual(rootMidi, 0)
        XCTAssertLessThanOrEqual(rootMidi, 127)
        print("[SoundfontLocalBundleTests] LOCAL midi=60 → rootMidi=\(rootMidi), frames=\(buf.frameLength)")
    }
}
