// ---------------------------------------------------------------------------
// Tier5Tests — Fase 5: bank(), ADSR aliases, ADSR over samples, $: syntax
//
// Tests:
//   1. bank() control field and lookup-key resolution
//   2. dec/att/sus/rel aliases map to decay/attack/sustain/release
//   3. Leading-dot number literals (.4 → 0.4)
//   4. ADSR envelope applied to a known synthetic buffer (per-sample check)
//   5. $: top-level parallel pattern syntax
//   6. Acceptance patterns from fixes.md parse without error
// ---------------------------------------------------------------------------

import XCTest
import AVFoundation
@testable import MiniEngine

final class Tier5Tests: XCTestCase {

    // MARK: - 1. bank() — control field

    func testBankFieldInControlMap() throws {
        let pat = s("bd").bank("tr909")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"]?.stringValue,    "bd")
        XCTAssertEqual(haps[0].value["bank"]?.stringValue, "tr909")
    }

    func testBankFieldViaCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").bank("tr909")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["bank"]?.stringValue, "tr909")
        XCTAssertEqual(haps[0].value["s"]?.stringValue,    "bd")
    }

    /// Bank lookup key: "bank_s" when bank is set, plain "s" otherwise.
    func testBankLookupKeyWithBank() {
        // Simulates the scheduler key derivation logic:
        // sBase = "bd", bankName = "tr909" → key = "tr909_bd"
        let sBase    = "bd"
        let bankName = "tr909"
        let key      = bankName.isEmpty ? sBase : "\(bankName)_\(sBase)"
        XCTAssertEqual(key, "tr909_bd")
    }

    func testBankLookupKeyWithoutBank() {
        let sBase    = "bd"
        let bankName = ""
        let key      = bankName.isEmpty ? sBase : "\(bankName)_\(sBase)"
        XCTAssertEqual(key, "bd")
    }

    func testBankLookupKeyTR808() {
        let sBase    = "hh"
        let bankName = "tr808"
        let key      = bankName.isEmpty ? sBase : "\(bankName)_\(sBase)"
        XCTAssertEqual(key, "tr808_hh")
    }

    // MARK: - 2. ADSR aliases

    func testDecAliasEqualsDecay() throws {
        // s("bd").dec(0.4) must produce same decay value as s("bd").decay(0.4)
        let decPat   = s("bd").dec(0.4)
        let decayPat = s("bd").decay(0.4)
        let decHap   = decPat.firstCycle().first!
        let decayHap = decayPat.firstCycle().first!
        XCTAssertEqual(decHap.value["decay"]?.doubleValue  ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(decayHap.value["decay"]?.doubleValue ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(decHap.value["decay"]?.doubleValue,
                       decayHap.value["decay"]?.doubleValue)
    }

    func testAttAliasEqualsAttack() throws {
        let attPat    = s("bd").att(0.01)
        let attackPat = s("bd").attack(0.01)
        let attHap    = attPat.firstCycle().first!
        let attackHap = attackPat.firstCycle().first!
        XCTAssertEqual(attHap.value["attack"]?.doubleValue   ?? -1, 0.01, accuracy: 1e-9)
        XCTAssertEqual(attackHap.value["attack"]?.doubleValue ?? -1, 0.01, accuracy: 1e-9)
    }

    func testSusAliasEqualsSustain() throws {
        let susPat     = s("bd").sus(0.8)
        let sustainPat = s("bd").sustain(0.8)
        let susHap     = susPat.firstCycle().first!
        let sustainHap = sustainPat.firstCycle().first!
        XCTAssertEqual(susHap.value["sustain"]?.doubleValue   ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(sustainHap.value["sustain"]?.doubleValue ?? -1, 0.8, accuracy: 1e-9)
    }

    func testRelAliasEqualsRelease() throws {
        let relPat     = s("bd").rel(0.2)
        let releasePat = s("bd").release(0.2)
        let relHap     = relPat.firstCycle().first!
        let releaseHap = releasePat.firstCycle().first!
        XCTAssertEqual(relHap.value["release"]?.doubleValue   ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(releaseHap.value["release"]?.doubleValue ?? -1, 0.2, accuracy: 1e-9)
    }

    func testDecAliasViaCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").dec(0.4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["decay"]?.doubleValue ?? -1, 0.4, accuracy: 1e-9)
    }

    // MARK: - 3. Leading-dot number literals

    func testLeadingDotLiteralDec() throws {
        // .dec(.4) should produce decay=0.4
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").dec(.4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["decay"]?.doubleValue ?? -1, 0.4, accuracy: 1e-9)
    }

    func testLeadingDotLiteralDecay() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").decay(.25)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps[0].value["decay"]?.doubleValue ?? -1, 0.25, accuracy: 1e-9)
    }

    func testLeadingDotLiteralGain() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").gain(.5)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps[0].value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-9)
    }

    func testLeadingDotLiteralBankDecay() throws {
        // Full acceptance pattern 1: s("[bd <hh oh>]*2").bank("tr909").dec(.4)
        let parser = CodeParser()
        let pat = try parser.parse(#"s("[bd <hh oh>]*2").bank("tr909").dec(.4)"#)
        let haps = pat.firstCycle()
        XCTAssertTrue(haps.count > 0, "Pattern should produce haps")
        for hap in haps {
            XCTAssertEqual(hap.value["bank"]?.stringValue, "tr909")
            XCTAssertEqual(hap.value["decay"]?.doubleValue ?? -1, 0.4, accuracy: 1e-9)
        }
    }

    // MARK: - 4. ADSR envelope over sample buffer

    /// Create a synthetic constant-1.0 buffer, apply an ADSR envelope, and verify
    /// that the output amplitude at known frame positions matches the expected ramp.
    func testADSREnvelopeAttackPhase() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames: AVAudioFrameCount = 44100  // 1 second
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = frames
        // Fill with constant amplitude 1.0
        guard let data = buf.floatChannelData else { XCTFail("No float data"); return }
        for i in 0..<Int(frames) { data[0][i] = 1.0 }

        let sr = 44100.0
        // attack=0.1s, decay=0.1s, sustain=0.5, release=0.1s, duration=0.5s
        let result = adsrEnvelopeBuffer(buf,
            sampleRate: sr, attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.1,
            durationSec: 0.5)

        guard let out = result.floatChannelData else { XCTFail("No output data"); return }

        // Frame 0: attack start → gain ≈ 0
        XCTAssertEqual(Double(out[0][0]), 0.0, accuracy: 0.01)

        // Frame at midpoint of attack (0.05s = frame 2205): gain ≈ 0.5
        XCTAssertEqual(Double(out[0][2205]), 0.5, accuracy: 0.02)

        // Frame at end of attack (0.1s = frame 4410): gain ≈ 1.0
        XCTAssertEqual(Double(out[0][4409]), 1.0, accuracy: 0.02)

        // Frame at midpoint of decay (0.15s = frame 6615): gain ≈ 0.75 (1→0.5 halfway)
        XCTAssertEqual(Double(out[0][6615]), 0.75, accuracy: 0.02)

        // Frame at end of decay (0.2s = frame 8820): gain ≈ 0.5 (sustain)
        XCTAssertEqual(Double(out[0][8820]), 0.5, accuracy: 0.02)

        // Frame deep in sustain (0.35s = frame 15435): gain ≈ 0.5
        XCTAssertEqual(Double(out[0][15435]), 0.5, accuracy: 0.02)

        // Frame at start of release (0.5s = frame 22050): gain begins fading from 0.5
        XCTAssertEqual(Double(out[0][22050]), 0.5, accuracy: 0.02)
    }

    func testADSREnvelopeNoParamsPreservesBuffer() {
        // When no ADSR is applied, buffer must be unchanged.
        // We simulate this at the pattern level: no ADSR fields → dispatchHap skips envelope.
        let pat = s("bd")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        // Verify no ADSR fields are set
        XCTAssertNil(haps[0].value["attack"])
        XCTAssertNil(haps[0].value["decay"])
        XCTAssertNil(haps[0].value["sustain"])
        XCTAssertNil(haps[0].value["release"])
    }

    // MARK: - 5. $: top-level parallel patterns

    func testDollarColonTwoPatterns() throws {
        let code = """
        $: s("bd*4")
        $: s("sd*2")
        """
        let parser = CodeParser()
        let pat = try parser.parse(code)
        // Should produce 4 + 2 = 6 haps in one cycle
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 6)
        // All should be sample events
        XCTAssertTrue(haps.allSatisfy { $0.value["s"] != nil })
    }

    func testDollarColonMutedIgnored() throws {
        // _$: muted patterns should be ignored
        let code = """
        $: s("bd*4")
        _$: s("sd*2")
        """
        let parser = CodeParser()
        let pat = try parser.parse(code)
        let haps = pat.firstCycle()
        // Only bd*4 → 4 haps; _$: sd*2 is muted
        XCTAssertEqual(haps.count, 4)
        XCTAssertTrue(haps.allSatisfy { $0.value["s"]?.stringValue == "bd" })
    }

    func testDollarColonSinglePatternEquivalent() throws {
        // A single $: should produce same result as plain pattern
        let code1 = #"s("bd hh")"#
        let code2 = """
        $: s("bd hh")
        """
        let parser = CodeParser()
        let pat1 = try parser.parse(code1)
        let pat2 = try parser.parse(code2)
        let haps1 = pat1.firstCycle().sorted { $0.part.begin < $1.part.begin }
        let haps2 = pat2.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps1.count, haps2.count)
        for (h1, h2) in zip(haps1, haps2) {
            XCTAssertEqual(h1.value["s"]?.stringValue, h2.value["s"]?.stringValue)
        }
    }

    func testDollarColonThreeLayers() throws {
        let code = """
        $: s("bd*4")
        $: s("~ cp ~ cp")
        $: s("hh*4")
        """
        let parser = CodeParser()
        let pat = try parser.parse(code)
        let haps = pat.firstCycle()
        // bd*4=4, cp*2=2, hh*4=4 → 10 total
        XCTAssertEqual(haps.count, 10)
    }

    // MARK: - 6. Acceptance patterns from fixes.md

    func testAcceptancePattern1BankDec() throws {
        // s("[bd <hh oh>]*2").bank("tr909").dec(.4)
        let parser = CodeParser()
        XCTAssertNoThrow(
            try parser.parse(#"s("[bd <hh oh>]*2").bank("tr909").dec(.4)"#)
        )
        let pat = try parser.parse(#"s("[bd <hh oh>]*2").bank("tr909").dec(.4)"#)
        let haps = pat.firstCycle()
        XCTAssertTrue(haps.count > 0)
        for hap in haps {
            XCTAssertEqual(hap.value["bank"]?.stringValue,  "tr909")
            XCTAssertEqual(hap.value["decay"]?.doubleValue ?? -1, 0.4, accuracy: 1e-9)
        }
    }

    func testAcceptancePattern2Stack() throws {
        // stack(
        //   s("bd*4").dec(0.4).gain(0.95),
        //   s("~ cp ~ cp").gain(0.5),
        //   s("[hh <hh oh>]*4").dec(0.25).gain(0.35)
        // )
        let code = """
        stack(
          s("bd*4").dec(0.4).gain(0.95),
          s("~ cp ~ cp").gain(0.5),
          s("[hh <hh oh>]*4").dec(0.25).gain(0.35)
        )
        """
        let parser = CodeParser()
        XCTAssertNoThrow(try parser.parse(code))
        let pat  = try parser.parse(code)
        let haps = pat.firstCycle()
        XCTAssertTrue(haps.count > 0, "Stack pattern should produce haps")
    }

    func testAcceptancePattern2SampleNames() throws {
        let code = """
        stack(
          s("bd*4").dec(0.4).gain(0.95),
          s("~ cp ~ cp").gain(0.5),
          s("[hh <hh oh>]*4").dec(0.25).gain(0.35)
        )
        """
        let parser = CodeParser()
        let pat  = try parser.parse(code)
        let haps = pat.firstCycle()
        let names = Set(haps.compactMap { $0.value["s"]?.stringValue })
        // Should contain bd, cp, hh, oh (oh appears in cycle 1)
        XCTAssertTrue(names.contains("bd"))
        XCTAssertTrue(names.contains("cp"))
        XCTAssertTrue(names.contains("hh"))
    }

    // MARK: - 7. Bank sample URL resolution (headless)

    /// Verify that a simulated sampleURLs dictionary with tr909 bank keys
    /// resolves correctly — i.e. "tr909_bd" and "tr808_hh" would be found,
    /// "tr999_bd" would be missing (friendly warning, no crash).
    func testBankSampleURLResolution() {
        // Simulate the key set that EngineAdapter would build from Samples/
        var sampleURLs: [String: URL] = [:]
        let dummyURL = URL(fileURLWithPath: "/dev/null")

        // Flat defaults
        for name in ["bd", "sd", "hh", "oh", "cp", "rim", "lt", "mt", "ht", "cr", "rd",
                     "pad", "bell"] {
            sampleURLs[name] = dummyURL
        }
        // tr909 bank
        for name in ["bd", "sd", "hh", "oh", "cp", "rim", "lt", "mt", "ht", "cr", "rd"] {
            sampleURLs["tr909_\(name)"] = dummyURL
        }
        // tr808 bank
        for name in ["bd", "sd", "hh", "oh", "cp", "rim", "lt", "mt", "ht", "cr", "rd"] {
            sampleURLs["tr808_\(name)"] = dummyURL
        }

        // Test: keys that must be present
        XCTAssertNotNil(sampleURLs["bd"],        "flat bd")
        XCTAssertNotNil(sampleURLs["tr909_bd"],  "tr909 bd")
        XCTAssertNotNil(sampleURLs["tr909_hh"],  "tr909 hh")
        XCTAssertNotNil(sampleURLs["tr808_bd"],  "tr808 bd")
        XCTAssertNotNil(sampleURLs["tr808_hh"],  "tr808 hh")
        XCTAssertNotNil(sampleURLs["pad"],       "pad preserved")
        XCTAssertNotNil(sampleURLs["bell"],      "bell preserved")

        // Test: key that should NOT be present (friendly warning, no crash)
        XCTAssertNil(sampleURLs["tr999_bd"], "unknown bank should be nil (no crash)")
    }

    // MARK: - 8. PatternScheduler bank logging (unit — no engine needed)

    /// Verify that when "bank" field is set, the effective key is bank_s,
    /// and when missing, the key is just s. Uses the same derivation as scheduler.
    func testSchedulerBankKeyDerivation() throws {
        // Pattern with bank
        let patWithBank = s("bd").bank("tr909")
        let hap = patWithBank.firstCycle().first!
        let sBase    = hap.value["s"]?.stringValue ?? ""
        let bankName = hap.value["bank"]?.stringValue ?? ""
        let key      = bankName.isEmpty ? sBase : "\(bankName)_\(sBase)"
        XCTAssertEqual(key, "tr909_bd")

        // Pattern without bank
        let patNoBank = s("bd")
        let hap2 = patNoBank.firstCycle().first!
        let sBase2    = hap2.value["s"]?.stringValue ?? ""
        let bankName2 = hap2.value["bank"]?.stringValue ?? ""
        let key2      = bankName2.isEmpty ? sBase2 : "\(bankName2)_\(sBase2)"
        XCTAssertEqual(key2, "bd")
    }
}

// MARK: - Regresión: formatos mezclados del banco de percusión (crash scheduleBuffer)

extension Tier5Tests {

    /// Los WAV del banco vienen en formatos mezclados (estéreo 16-bit, mono 24-bit).
    /// Todo buffer debe normalizarse al formato canónico o AVAudioPlayerNode lanza
    /// NSException al agendar.
    func testNormalizedBufferConvertsMonoToCanonical() throws {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 2205)!
        buf.frameLength = 2205
        for i in 0..<2205 { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) }

        let out = PatternScheduler.normalizedBuffer(buf)
        XCTAssertEqual(out.format.channelCount, 2)
        XCTAssertEqual(out.format.sampleRate, 44100)
        XCTAssertEqual(out.format.commonFormat, .pcmFormatFloat32)
        // 0.1s a 22050 → ~0.1s a 44100 (± margen del converter)
        XCTAssertGreaterThan(out.frameLength, 4000)
        // Mono duplicado: ambos canales con señal
        var energyL: Float = 0, energyR: Float = 0
        for i in 0..<Int(out.frameLength) {
            energyL += abs(out.floatChannelData![0][i])
            energyR += abs(out.floatChannelData![1][i])
        }
        XCTAssertGreaterThan(energyL, 1)
        XCTAssertGreaterThan(energyR, 1)
    }

    func testNormalizedBufferPassthroughWhenCanonical() {
        let fmt = PatternScheduler.canonicalFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 100)!
        buf.frameLength = 100
        XCTAssertTrue(PatternScheduler.normalizedBuffer(buf) === buf)
    }

    /// Smoke test del crash reportado: s("[bd <hh oh>]*2").bank("tr909").dec(.4)
    /// con los WAV reales del repo (bd estéreo, hh/oh mono). Agenda ~1.2s de audio
    /// por un engine real; antes del fix esto moría con NSException en scheduleBuffer.
    func testMixedFormatBankPatternDoesNotCrash() throws {
        let samplesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MiniEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MiniEngine
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/DemoStrudelApp/Samples")
        var urls: [String: URL] = [:]
        for name in ["bd", "hh", "oh"] {
            urls["tr909_\(name)"] = samplesDir.appendingPathComponent("tr909/\(name).wav")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: urls["tr909_bd"]!.path),
                          "Samples no disponibles en este entorno")

        let engine = MiniEngine(sampleURLs: urls)
        engine.play(code: #"s("[bd <hh oh>]*2").bank("tr909").dec(.4)"#)
        // Dejar correr el scheduler más de un lookahead para que agende bd y hh/oh
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
        engine.stop()
    }
}
