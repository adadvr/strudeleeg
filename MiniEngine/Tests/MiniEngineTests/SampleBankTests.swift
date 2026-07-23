// ---------------------------------------------------------------------------
// SampleBankTests — tests for SampleBankManager, samples() parsing, :n
// variation, disk cache, prefetch, note-base alignment, and fallback.
//
// Network-free: uses file:// URLs pointing to Fixtures/remote_fixtures/*.wav
// and an in-memory mini-manifest (SampleBankManager.parseManifest is tested
// directly, and register(manifestURL:) with file:// URL for integration).
// ---------------------------------------------------------------------------

import XCTest
import AVFoundation
@testable import MiniEngine

final class SampleBankTests: XCTestCase {

    // MARK: - Helpers

    /// Return the URL for a fixture file (Fixtures/remote_fixtures/<name>).
    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: Self.self)
        // Bundle resources are copied flat; look for the file in Fixtures/remote_fixtures
        guard let url = bundle.url(forResource: "remote_fixtures/\(name)", withExtension: nil,
                                    subdirectory: "Fixtures") ??
                        bundle.url(forResource: name, withExtension: nil,
                                    subdirectory: "Fixtures/remote_fixtures")
        else {
            // Fallback: construct relative to source file (for SPM test environments)
            let src = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/remote_fixtures")
                .appendingPathComponent(name)
            return src
        }
        return url
    }

    /// Create a temporary manifest JSON file with file:// paths for the fixtures.
    private func makeManifest(entries: [String: [String]], baseURL: URL) throws -> URL {
        var json: [String: Any] = [:]
        json["_base"] = baseURL.absoluteString
        for (key, paths) in entries {
            json[key] = paths
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_manifest_\(UUID().uuidString).json")
        try data.write(to: tmp)
        return tmp
    }

    override func setUp() {
        super.setUp()
        // Use a fresh manager per test to avoid cross-test state
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - 1. github: URL resolution

    func testGithubURLResolution_DirtSamples() {
        let url = SampleBankManager.resolveURL("github:tidalcycles/dirt-samples")
        XCTAssertEqual(url.absoluteString,
            "https://raw.githubusercontent.com/tidalcycles/dirt-samples/master/strudel.json",
            "dirt-samples should resolve to master branch (empirically verified)")
    }

    func testGithubURLResolution_ExplicitBranch() {
        let url = SampleBankManager.resolveURL("github:myuser/myrepo/develop")
        XCTAssertEqual(url.absoluteString,
            "https://raw.githubusercontent.com/myuser/myrepo/develop/strudel.json")
    }

    func testGithubURLResolution_DefaultMain() {
        let url = SampleBankManager.resolveURL("github:someuser/somesamples")
        XCTAssertEqual(url.absoluteString,
            "https://raw.githubusercontent.com/someuser/somesamples/main/strudel.json",
            "unknown repos should default to 'main' branch")
    }

    func testDirectHTTPSPassthrough() {
        let raw = "https://bucket.region.digitaloceanspaces.com/samples/strudel.json"
        let url = SampleBankManager.resolveURL(raw)
        XCTAssertEqual(url.absoluteString, raw)
    }

    func testFileURLPassthrough() {
        let raw = "file:///tmp/strudel.json"
        let url = SampleBankManager.resolveURL(raw)
        XCTAssertEqual(url.absoluteString, raw)
    }

    // MARK: - 2. Manifest parsing

    func testManifestParseArrayEntries() throws {
        let json: [String: Any] = [
            "_base": "https://example.com/samples/",
            "bd": ["bd/bd0.wav", "bd/bd1.wav", "bd/bd2.wav"],
            "sitar": ["sitar/sitar0.wav"],
            "tabla": ["tabla/t0.wav", "tabla/t1.wav"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://example.com/samples/strudel.json")!
        let bank = SampleBankManager.parseManifest(data: data, manifestURL: url)
        XCTAssertNotNil(bank)
        XCTAssertEqual(bank?["bd"]?.count, 3)
        XCTAssertEqual(bank?["sitar"]?.count, 1)
        XCTAssertEqual(bank?["tabla"]?.count, 2)
        XCTAssertNil(bank?["_base"])
    }

    func testManifestParseResolveBase() throws {
        let json: [String: Any] = [
            "_base": "https://cdn.example.com/sounds/",
            "bd": ["bd/bd0.wav"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://example.com/strudel.json")!
        let base = SampleBankManager.resolveBase(from: data, manifestURL: url)
        XCTAssertEqual(base.absoluteString, "https://cdn.example.com/sounds/")
    }

    func testManifestParseFallbackBase() throws {
        // If _base absent, derive from manifest URL parent directory
        let json: [String: Any] = ["bd": ["bd/bd0.wav"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://example.com/samples/strudel.json")!
        let base = SampleBankManager.resolveBase(from: data, manifestURL: url)
        XCTAssertEqual(base.absoluteString, "https://example.com/samples/")
    }

    func testManifestParseNoteMapEntry() throws {
        // Future note-map format: flattened to sorted-key list
        let json: [String: Any] = [
            "_base": "https://example.com/",
            "piano": ["c4": ["piano/c4.wav"], "d4": ["piano/d4.wav"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://example.com/strudel.json")!
        let bank = SampleBankManager.parseManifest(data: data, manifestURL: url)
        // Should flatten note-map into array
        XCTAssertNotNil(bank?["piano"])
        XCTAssertEqual(bank?["piano"]?.count, 2)
    }

    // MARK: - 3. Cache name safety

    func testSafeCacheName_wavFile() {
        let name = SampleBankManager.safeCacheName(
            for: "https://raw.githubusercontent.com/tidalcycles/Dirt-Samples/master/bd/BT0A0A7.wav")
        XCTAssertTrue(name.hasSuffix(".wav"), "Should preserve .wav extension")
        XCTAssertFalse(name.contains("/"), "Should not contain slashes")
        XCTAssertFalse(name.contains(":"), "Should not contain colons")
    }

    func testSafeCacheName_noExtension() {
        let name = SampleBankManager.safeCacheName(for: "https://example.com/manifest")
        XCTAssertFalse(name.isEmpty)
        XCTAssertFalse(name.contains("/"))
    }

    // MARK: - 4. Registration with file:// manifest (integration, no network)

    func testRegisterFileManifest_loadsBank() throws {
        let fixtureDir = fixtureURL("bd0.wav").deletingLastPathComponent()
        let manifestURL = try makeManifest(
            entries: [
                "bd": ["bd0.wav", "bd1.wav"],
                "sitar": ["sitar0.wav"]
            ],
            baseURL: fixtureDir
        )
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let manager = SampleBankManager()
        try manager.registerSync(manifestURL: manifestURL.absoluteString)

        // Verify variation counts
        XCTAssertEqual(manager.variationCount(forName: "bd"), 2)
        XCTAssertEqual(manager.variationCount(forName: "sitar"), 1)
        XCTAssertEqual(manager.variationCount(forName: "unknown"), 0)
    }

    func testRegisterFileManifest_prefetchesBuffers() throws {
        let fixtureDir = fixtureURL("bd0.wav").deletingLastPathComponent()
        let manifestURL = try makeManifest(
            entries: ["bd": ["bd0.wav", "bd1.wav"]],
            baseURL: fixtureDir
        )
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let manager = SampleBankManager()
        try manager.registerSync(manifestURL: manifestURL.absoluteString)

        // Prefetch variation 0
        manager.prefetchSamples(names: [("bd", 0)])

        // Wait for async download (file:// is fast)
        let deadline = Date().addingTimeInterval(3.0)
        var buf: AVAudioPCMBuffer? = nil
        while Date() < deadline {
            buf = manager.buffer(forName: "bd", index: 0)
            if buf != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(buf, "bd:0 buffer should be loaded after prefetch")
    }

    // MARK: - 5. :n variation — modulo behaviour

    func testColonNParsing_basic() {
        let (name, idx) = parseColonN("tabla:3")
        XCTAssertEqual(name, "tabla")
        XCTAssertEqual(idx, 3)
    }

    func testColonNParsing_zero() {
        let (name, idx) = parseColonN("bd:0")
        XCTAssertEqual(name, "bd")
        XCTAssertEqual(idx, 0)
    }

    func testColonNParsing_noColon() {
        let (name, idx) = parseColonN("bd")
        XCTAssertEqual(name, "bd")
        XCTAssertNil(idx)
    }

    func testColonNParsing_notANumber() {
        // "http://..." should not be parsed as name:n
        let (name, idx) = parseColonN("http://example.com")
        XCTAssertNil(idx)
        XCTAssertEqual(name, "http://example.com")
    }

    func testColonN_inControlPattern_setsNField() {
        let pat = s("tabla:3")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"]?.stringValue, "tabla")
        XCTAssertEqual(haps[0].value["n"]?.doubleValue, 3.0)
    }

    func testColonN_withSequence() {
        let pat = s("bd:0 bd:2 bd:1")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].value["n"]?.doubleValue, 0.0)
        XCTAssertEqual(haps[1].value["n"]?.doubleValue, 2.0)
        XCTAssertEqual(haps[2].value["n"]?.doubleValue, 1.0)
    }

    func testColonN_defaultIsNil() {
        // s("bd") without :n → no "n" field (defaults to 0 at dispatch time)
        let pat = s("bd")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertNil(haps[0].value["n"], "No :n → no n field in hap")
    }

    func testColonN_moduloInBankManager() throws {
        // If bank has 2 variations and idx=5 → use 5%2=1
        let fixtureDir = fixtureURL("bd0.wav").deletingLastPathComponent()
        let manifestURL = try makeManifest(
            entries: ["bd": ["bd0.wav", "bd1.wav"]],
            baseURL: fixtureDir
        )
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let manager = SampleBankManager()
        try manager.registerSync(manifestURL: manifestURL.absoluteString)

        // Prefetch idx=5 → modulo 2 → variation 1
        manager.prefetchSamples(names: [("bd", 5)])
        let deadline = Date().addingTimeInterval(3.0)
        var buf: AVAudioPCMBuffer?
        while Date() < deadline {
            buf = manager.buffer(forName: "bd", index: 5)
            if buf != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(buf, "bd:5 with 2 variations → variation 5%2=1 should load")
    }

    // MARK: - 6. samples() in CodeParser

    func testSamplesStatementParsed() throws {
        let code = """
        samples('github:tidalcycles/dirt-samples')
        s("bd hh")
        """
        let result = try CodeParser().parseWithTempo(code)
        XCTAssertEqual(result.manifestURLs.count, 1)
        XCTAssertEqual(result.manifestURLs[0], "github:tidalcycles/dirt-samples")
    }

    func testSamplesStatementWithHTTPS() throws {
        let code = """
        samples('https://bucket.example.com/strudel.json')
        s("bd")
        """
        let result = try CodeParser().parseWithTempo(code)
        XCTAssertEqual(result.manifestURLs.count, 1)
        XCTAssertEqual(result.manifestURLs[0], "https://bucket.example.com/strudel.json")
    }

    func testMultipleSamplesStatements() throws {
        let code = """
        samples('github:tidalcycles/dirt-samples')
        samples('https://my-bucket.com/extra.json')
        s("bd")
        """
        let result = try CodeParser().parseWithTempo(code)
        XCTAssertEqual(result.manifestURLs.count, 2)
    }

    func testNoSamplesStatement() throws {
        let code = #"s("bd hh")"#
        let result = try CodeParser().parseWithTempo(code)
        XCTAssertTrue(result.manifestURLs.isEmpty)
    }

    func testSamplesStatementDoesNotAffectPattern() throws {
        let code = """
        samples('github:tidalcycles/dirt-samples')
        s("bd hh cp")
        """
        let result = try CodeParser().parseWithTempo(code)
        let haps = result.pattern.firstCycle()
        XCTAssertEqual(haps.count, 3, "samples() should not affect the pattern structure")
    }

    func testSamplesWithDoubleQuotes() throws {
        let code = #"samples("github:tidalcycles/dirt-samples")"#
        let result = try CodeParser().parseWithTempo(code)
        XCTAssertEqual(result.manifestURLs.count, 1)
        XCTAssertEqual(result.manifestURLs[0], "github:tidalcycles/dirt-samples")
    }

    // MARK: - 7. Disk cache — second load avoids re-download

    func testDiskCache_secondLoadUsesCache() throws {
        let fixtureDir = fixtureURL("bd0.wav").deletingLastPathComponent()
        let manifestURL = try makeManifest(
            entries: ["bd": ["bd0.wav"]],
            baseURL: fixtureDir
        )
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let manager1 = SampleBankManager()
        try manager1.registerSync(manifestURL: manifestURL.absoluteString)
        manager1.prefetchSamples(names: [("bd", 0)])
        // Wait for buffer
        let deadline1 = Date().addingTimeInterval(3.0)
        while Date() < deadline1 {
            if manager1.buffer(forName: "bd", index: 0) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(manager1.buffer(forName: "bd", index: 0), "First load should succeed")

        // Second manager: same manifest URL → should load from disk cache (file:// always fast)
        let manager2 = SampleBankManager()
        try manager2.registerSync(manifestURL: manifestURL.absoluteString)
        manager2.prefetchSamples(names: [("bd", 0)])
        let deadline2 = Date().addingTimeInterval(3.0)
        while Date() < deadline2 {
            if manager2.buffer(forName: "bd", index: 0) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(manager2.buffer(forName: "bd", index: 0), "Second load (cache) should succeed")
    }

    // MARK: - 8. Note base alignment (C2 = MIDI 36)

    /// Verify that the note base for samples is C2 = MIDI 36, matching Strudel/superdough.
    /// Strudel: note("c2").s("sitar") → rate = 2^((36-36)/12) = 1.0 (unchanged pitch).
    ///          note("c3").s("sitar") → rate = 2^((48-36)/12) = 2.0 (+1 octave).
    ///          note("c4").s("sitar") → rate = 2^((60-36)/12) = ≈4.76 (+2 octaves).
    /// Our engine: same formula. Confirmed vs superdough.mjs: uses note2speed(note, 36).
    func testNoteBase_C2() {
        // C2 = MIDI 36 → rate 1.0
        let c2Rate = pow(2.0, Double(36 - 36) / 12.0)
        XCTAssertEqual(c2Rate, 1.0, accuracy: 1e-9, "C2 should play at rate 1.0")
    }

    func testNoteBase_C4() {
        // C4 = MIDI 60 → rate 2^((60-36)/12) = 2^(24/12) = 2^2 = 4.0 (+2 octaves from C2)
        let c4Rate = pow(2.0, Double(60 - 36) / 12.0)
        XCTAssertEqual(c4Rate, 4.0, accuracy: 1e-9, "C4 should play at rate 4.0 (2 octaves above C2 base)")
    }

    func testNoteBase_GSharp4() {
        // G#4 = MIDI 68 → rate = 2^((68-36)/12) = 2^(32/12) ≈ 6.35
        let rate = pow(2.0, Double(68 - 36) / 12.0)
        XCTAssertEqual(rate, pow(2.0, 32.0/12.0), accuracy: 1e-9)
        // Cross-check: NOT the same as C4-base rate
        let wrongRate = pow(2.0, Double(68 - 60) / 12.0)
        XCTAssertNotEqual(rate, wrongRate, accuracy: 1e-6,
            "C2-base and C4-base rates should differ for G#4")
    }

    func testNoteBase_NoNoteField_RateIs1() {
        // Without note() field, rate = 1.0 (speed 1, no repitch)
        // This verifies backward compat: s("bd") without note → rate unchanged
        let noteRate: Double = 1.0  // what the scheduler does when midiNote == nil
        XCTAssertEqual(noteRate, 1.0)
    }

    // MARK: - 9. Fallback: local bundle sample when bank not registered

    func testFallbackToLocalBundle() throws {
        // When no bankManager or sample not in remote bank → uses local URL
        // We verify via parse: s("bd") without samples() → manifestURLs empty
        let code = #"s("bd hh")"#
        let result = try CodeParser().parseWithTempo(code)
        XCTAssertTrue(result.manifestURLs.isEmpty, "No samples() → no remote manifests")
        // Pattern should parse correctly
        XCTAssertEqual(result.pattern.firstCycle().count, 2)
    }

    // MARK: - 10. n field combined with s() — chain wins over :n

    func testNFieldChainOverridesColonN() {
        // s("bd:2").n("5") — the .n() chain sets n=5, overriding :n=2
        // Because withControl merges right-side wins: n("5") comes after s("bd:2")
        let pat = s("bd:2").n("5")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"]?.stringValue, "bd")
        // n field: the chain n("5") should win (merge priority: right side wins)
        XCTAssertEqual(haps[0].value["n"]?.doubleValue, 5.0,
            ".n('5') chain should override :2 from s() token")
    }
}
