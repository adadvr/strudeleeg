import Foundation
import MiniEngine

// ---------------------------------------------------------------------------
// EngineAdapter — bridges MiniEngine to the app's AudioDemoEngine protocol.
// MiniEngine is Bundle-independent; we resolve sample URLs here from the
// app bundle and pass them to MiniEngine at init time.
//
// Sample key naming convention:
//   • Root-level Samples/bd.wav        → key "bd"
//   • Subfolder  Samples/tr909/bd.wav  → key "tr909_bd"
//   • Subfolder  Samples/tr808/sd.wav  → key "tr808_sd"
//
// This mirrors the Strudel convention where bank("tr909") prepends "tr909_"
// to the sample name. EngineAdapter builds the dictionary by recursively
// enumerating the Samples/ bundle resource path.
// ---------------------------------------------------------------------------

final class NativeEngineAdapter: AudioDemoEngine {

    private let engine: MiniEngine

    /// Forwarded from MiniEngine.onParseError; set by DemoViewModel.
    var onParseError: ((String) -> Void)? {
        didSet { engine.onParseError = onParseError }
    }

    init() {
        let bundle = Bundle.module
        var urls: [String: URL] = [:]

        // Locate the Samples/ directory in the bundle
        if let samplesDir = bundle.url(forResource: "Samples", withExtension: nil) {
            urls = EngineAdapter_buildSampleURLs(from: samplesDir)
        } else {
            print("[EngineAdapter] Warning: Samples/ directory not found in bundle")
        }

        // Log found samples for diagnostics
        let sorted = urls.keys.sorted()
        print("[EngineAdapter] Loaded \(sorted.count) sample(s): \(sorted.prefix(20).joined(separator: ", "))\(sorted.count > 20 ? "..." : "")")

        self.engine = MiniEngine(sampleURLs: urls)
    }

    func play(code: String) {
        engine.play(code: code)
    }

    func stop() {
        engine.stop()
    }
}

// MARK: - Recursive sample URL builder

/// Enumerates `samplesDir` recursively and builds a [key: URL] dictionary.
/// Key derivation:
///   • File directly in samplesDir   → key = filename without extension  (e.g. "bd")
///   • File one level deep            → key = subfolder_filename           (e.g. "tr909_bd")
///   • Deeper nesting               → key = parent1_parent2_..._filename  (multi-level)
private func EngineAdapter_buildSampleURLs(from samplesDir: URL) -> [String: URL] {
    let fm = FileManager.default
    var urls: [String: URL] = [:]

    guard let enumerator = fm.enumerator(
        at: samplesDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        print("[EngineAdapter] Could not enumerate Samples/ directory")
        return urls
    }

    for case let fileURL as URL in enumerator {
        // Skip directories
        let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir { continue }

        // Only accept .wav files
        guard fileURL.pathExtension.lowercased() == "wav" else { continue }

        // Compute relative path from samplesDir
        let relativePath = fileURL.path.dropFirst(samplesDir.path.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // relativePath examples: "bd.wav", "tr909/bd.wav", "tr808/sd.wav"

        let components = relativePath.components(separatedBy: "/")
        let filename   = (components.last! as NSString).deletingPathExtension.lowercased()

        let key: String
        if components.count == 1 {
            // Root-level file: key = filename
            key = filename
        } else {
            // Subfolder file: key = subfolder(s)_filename
            let folders = components.dropLast().map { $0.lowercased() }
            key = (folders + [filename]).joined(separator: "_")
        }

        urls[key] = fileURL
    }

    return urls
}
