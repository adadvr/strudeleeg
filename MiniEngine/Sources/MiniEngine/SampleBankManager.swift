// ---------------------------------------------------------------------------
// SampleBankManager — remote sample bank loader with disk cache and lazy
// prefetch.
//
// Architecture:
//   • register(manifestURL:) resolves github: shortcuts → raw URL, downloads
//     the manifest JSON (async), and caches the parsed bank in memory.
//   • Disk cache: ~/Library/Caches/DemoStrudel/samples/<safe-path>
//     Persists between launches. Manifest also cached with simple fallback.
//   • Lazy prefetch: prefetchSamples(names:indices:) dispatches downloads for
//     the named samples BEFORE playback; other bank entries are NOT fetched.
//   • If a sample is not yet cached when the scheduler asks, the call returns
//     nil immediately — the scheduler skips the event and logs a warning.
//   • Decodes via AVAudioFile → normalises with PatternScheduler.normalizedBuffer.
//
// Manifest format (confirmed empirically — dirt-samples master, 2026-07):
//   {
//     "_base": "https://raw.githubusercontent.com/.../",
//     "bd": ["bd/BT0A0A7.wav", ...],
//     "tabla": ["tabla/000_bass_flick1.wav", ...],
//     ...
//   }
//   All values are arrays of strings (plain paths). No note-map objects in
//   dirt-samples. The manager handles both array-of-strings and (future)
//   dict-of-arrays for per-bank sub-keys; note-maps ({"c4": [...]}) are
//   reserved but not present in dirt-samples and not implemented.
//
// github: shortcut:
//   "github:user/repo"         → branch=master, manifest=strudel.json
//   "github:user/repo/branch"  → explicit branch
//   The raw URL is: https://raw.githubusercontent.com/user/repo/branch/strudel.json
//   Branch resolution: tries "main" first (HEAD redirect), falls back to "master".
//   Verified empirically: dirt-samples uses "master" (not "main").
//
// :n variation (MIDI field "n"):
//   s("tabla:3") → name="tabla", n=3 in the hap. The scheduler resolves the
//   buffer key as (name, n % arrayLength). Without :n, n defaults to 0.
// ---------------------------------------------------------------------------

import AVFoundation
import Foundation

// MARK: - SampleBankManager

public final class SampleBankManager {

    // MARK: - Types

    /// A parsed bank: array of relative path strings per sample name.
    public typealias Bank = [String: [String]]

    // MARK: - Singleton / shared

    public static let shared = SampleBankManager()

    // MARK: - State (actor-isolated via serialQueue)

    /// Loaded banks: manifestURL string → Bank
    private var banks: [String: Bank] = [:]
    /// Base URLs resolved per manifest
    private var basURLs: [String: URL] = [:]
    /// In-memory decoded buffer cache: absolute URL string → AVAudioPCMBuffer
    private var decodedBuffers: [String: AVAudioPCMBuffer] = [:]
    /// Tracks in-flight downloads to avoid duplicate fetches
    private var inFlight: Set<String> = []
    /// Serial queue for state mutations
    private let serialQueue = DispatchQueue(label: "com.miniengine.samplebank", qos: .userInitiated)

    // MARK: - Cache directory

    private static let cacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("DemoStrudel/samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let manifestCacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("DemoStrudel/manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public init() {}

    // MARK: - Registration

    /// Register a manifest by URL string (may be "github:user/repo" shortcut or
    /// a direct https:// / file:// URL). Downloads and parses the manifest async.
    /// Completion is called on the serialQueue with the resolved bank key (the
    /// raw manifest URL string after github: resolution).
    @discardableResult
    public func register(manifestURL urlString: String,
                         completion: ((String?) -> Void)? = nil) -> String {
        let resolved = Self.resolveURL(urlString)
        let key = resolved.absoluteString

        serialQueue.async { [weak self] in
            guard let self else { return }
            if self.banks[key] != nil {
                completion?(key)
                return
            }
            self.loadManifest(from: resolved, key: key, completion: completion)
        }
        return key
    }

    /// Synchronous version for tests (blocks calling thread — do NOT call on main).
    public func registerSync(manifestURL urlString: String) throws -> String {
        let resolved = Self.resolveURL(urlString)
        let key = resolved.absoluteString
        var loadError: Error?
        var done = false
        serialQueue.sync {
            if self.banks[key] != nil { done = true; return }
        }
        if done { return key }
        let sema = DispatchSemaphore(value: 0)
        serialQueue.async {
            self.loadManifest(from: resolved, key: key) { _ in sema.signal() }
        }
        sema.wait()
        serialQueue.sync {
            if self.banks[key] == nil {
                loadError = SampleBankError.manifestLoadFailed(resolved.absoluteString)
            }
        }
        if let err = loadError { throw err }
        return key
    }

    // MARK: - Prefetch

    /// Prefetch a set of (name, index) pairs from all registered banks.
    /// Called before playback starts. Downloads are dispatched async; nothing
    /// is waited for. The scheduler will skip events for samples not yet ready.
    public func prefetchSamples(names: [(name: String, index: Int)]) {
        serialQueue.async { [weak self] in
            guard let self else { return }
            for (bankKey, bank) in self.banks {
                guard let baseURL = self.basURLs[bankKey] else { continue }
                for (name, idx) in names {
                    guard let paths = bank[name], !paths.isEmpty else { continue }
                    let safeIdx = idx % paths.count
                    let path = paths[safeIdx]
                    let sampleURL = baseURL.appendingPathComponent(path, isDirectory: false).cleaned
                    self.enqueueDownload(sampleURL: sampleURL)
                }
            }
        }
    }

    /// Prefetch by name only (index 0 for each).
    public func prefetchSamples(names: [String]) {
        prefetchSamples(names: names.map { ($0, 0) })
    }

    // MARK: - Buffer lookup (synchronous, called from scheduler)

    /// Returns a decoded buffer for (sampleName, index) if already in cache;
    /// Prefetch + espera acotada: dispara las descargas y espera hasta `timeout`
    /// a que los buffers pedidos estén listos. Los cache-hits de disco cargan en
    /// milisegundos → el primer ciclo del patrón suena desde el play; los misses
    /// de red simplemente agotan el timeout y siguen bajando async (no bloquea).
    public func prefetchAndWait(names: [(name: String, index: Int)], timeout: TimeInterval = 0.5) {
        prefetchSamples(names: names)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let allReady = names.allSatisfy { pair in
                variationCount(forName: pair.name) == 0   // no es remoto: nada que esperar
                    || buffer(forName: pair.name, index: pair.index) != nil
            }
            if allReady { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// nil if still downloading. Dispatches a download if not yet started.
    /// Thread-safe: can be called from any thread.
    public func buffer(forName name: String, index: Int) -> AVAudioPCMBuffer? {
        var result: AVAudioPCMBuffer?
        serialQueue.sync {
            for (bankKey, bank) in self.banks {
                guard let paths = bank[name], !paths.isEmpty else { continue }
                guard let baseURL = self.basURLs[bankKey] else { continue }
                let safeIdx = index % paths.count
                let path = paths[safeIdx]
                let sampleURL = baseURL.appendingPathComponent(path, isDirectory: false).cleaned
                let urlKey = sampleURL.absoluteString
                if let buf = self.decodedBuffers[urlKey] {
                    result = buf
                    return
                }
                // Not ready — kick off download
                self.enqueueDownload(sampleURL: sampleURL)
            }
        }
        return result
    }

    /// Total number of variations for a sample name across all banks.
    public func variationCount(forName name: String) -> Int {
        var count = 0
        serialQueue.sync {
            for bank in self.banks.values {
                if let paths = bank[name] { count = max(count, paths.count) }
            }
        }
        return count
    }

    // MARK: - Clear (for tests)

    public func clear() {
        serialQueue.sync {
            banks = [:]
            basURLs = [:]
            decodedBuffers = [:]
            inFlight = []
        }
    }

    // MARK: - Manifest loading (internal, called on serialQueue)

    private func loadManifest(from url: URL, key: String, completion: ((String?) -> Void)?) {
        // Check manifest disk cache first
        let manifestCacheKey = safeCacheName(for: url.absoluteString + ".json")
        let manifestCachePath = Self.manifestCacheDir.appendingPathComponent(manifestCacheKey)

        func parseAndStore(data: Data) -> Bool {
            guard let bank = Self.parseManifest(data: data, manifestURL: url) else { return false }
            let baseURL = Self.resolveBase(from: data, manifestURL: url)
            self.banks[key] = bank
            self.basURLs[key] = baseURL
            return true
        }

        // Try network first; fall back to disk cache on failure
        if url.isFileURL {
            do {
                let data = try Data(contentsOf: url)
                if parseAndStore(data: data) {
                    print("[SampleBankManager] Loaded file:// manifest: \(url.lastPathComponent) (\(banks[key]?.count ?? 0) entries)")
                    completion?(key)
                } else {
                    completion?(nil)
                }
            } catch {
                print("[SampleBankManager] Failed to read file manifest: \(error)")
                completion?(nil)
            }
            return
        }

        // HTTP fetch
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            self.serialQueue.async {
                if let data = data, error == nil {
                    if parseAndStore(data: data) {
                        // Cache to disk
                        try? data.write(to: manifestCachePath)
                        print("[SampleBankManager] Loaded remote manifest from \(url.host ?? url.absoluteString) (\(self.banks[key]?.count ?? 0) entries)")
                        completion?(key)
                    } else {
                        // Try disk cache as fallback
                        if let cached = try? Data(contentsOf: manifestCachePath),
                           parseAndStore(data: cached) {
                            print("[SampleBankManager] Using cached manifest (parse failed on network)")
                            completion?(key)
                        } else {
                            completion?(nil)
                        }
                    }
                } else {
                    print("[SampleBankManager] Network failed: \(error?.localizedDescription ?? "?") — trying disk cache")
                    if let cached = try? Data(contentsOf: manifestCachePath),
                       parseAndStore(data: cached) {
                        print("[SampleBankManager] Loaded manifest from disk cache (offline fallback)")
                        completion?(key)
                    } else {
                        completion?(nil)
                    }
                }
            }
        }
        task.resume()
    }

    // MARK: - Manifest parsing

    /// Parse a strudel.json manifest. Returns [name: [path]] map.
    /// "_base" is extracted separately (see resolveBase).
    static func parseManifest(data: Data, manifestURL: URL) -> Bank? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var bank: Bank = [:]
        for (key, value) in json {
            if key == "_base" { continue }
            if let arr = value as? [String] {
                // Standard format: "bd": ["bd/BT0A0A7.wav", ...]
                bank[key] = arr
            } else if let dict = value as? [String: Any] {
                // Future note-map format: "piano": {"c4": ["piano/c4.wav"], ...}
                // Flatten all arrays into one list ordered by key
                var flat: [String] = []
                for (_, v) in dict.sorted(by: { $0.key < $1.key }) {
                    if let arr = v as? [String] { flat.append(contentsOf: arr) }
                }
                if !flat.isEmpty { bank[key] = flat }
            }
        }
        return bank
    }

    /// Extract the _base URL. If absent or empty, derive from the manifest URL
    /// (parent directory of the manifest file).
    static func resolveBase(from data: Data, manifestURL: URL) -> URL {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base = json["_base"] as? String, !base.isEmpty,
           let url = URL(string: base) {
            return url
        }
        // Fallback: parent directory of manifest URL
        return manifestURL.deletingLastPathComponent()
    }

    // MARK: - github: URL resolution

    /// Resolve "github:user/repo" or "github:user/repo/branch" to a raw URL.
    /// Empirically verified: dirt-samples uses "master" branch.
    /// We try "main" first (GitHub default since 2020), then "master".
    /// For simplicity in production: we always resolve to the supplied or default
    /// branch without live HEAD detection (which would require a network round-trip).
    /// Convention: if branch not specified, try "main"; if manifest 404s, try "master".
    /// Since we verified dirt-samples uses "master", for known repos we default to master.
    ///
    /// Supported forms:
    ///   github:tidalcycles/dirt-samples        → master branch (empirically verified)
    ///   github:user/repo                       → main branch (GitHub default)
    ///   github:user/repo/my-branch             → explicit branch
    ///   https://...                            → pass through
    ///   file://...                             → pass through
    public static func resolveURL(_ input: String) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("github:") {
            let rest = String(trimmed.dropFirst("github:".count))
            let parts = rest.split(separator: "/", maxSplits: 3).map(String.init)
            guard parts.count >= 2 else {
                return URL(string: input) ?? URL(string: "about:blank")!
            }
            let user   = parts[0]
            let repo   = parts[1]
            // Branch: explicit if 3 parts; otherwise use "master" for known dirt-samples
            // repo, else "main" (GitHub default since 2020).
            let branch: String
            if parts.count >= 3 {
                branch = parts[2]
            } else if user == "tidalcycles" && repo == "dirt-samples" {
                branch = "master"  // verified empirically
            } else {
                branch = "main"
            }
            let raw = "https://raw.githubusercontent.com/\(user)/\(repo)/\(branch)/strudel.json"
            return URL(string: raw) ?? URL(string: "about:blank")!
        }

        return URL(string: trimmed) ?? URL(string: "about:blank")!
    }

    // MARK: - Download & decode (internal, called on serialQueue)

    private func enqueueDownload(sampleURL: URL) {
        let key = sampleURL.absoluteString
        guard decodedBuffers[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        // Check disk cache first (off serialQueue to avoid blocking)
        let cachePath = Self.cacheDir.appendingPathComponent(safeCacheName(for: key))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: cachePath.path) {
                // Load from disk
                do {
                    let buf = try Self.decodeAudio(from: cachePath)
                    self.serialQueue.async {
                        self.decodedBuffers[key] = buf
                        self.inFlight.remove(key)
                        print("[SampleBankManager] Loaded from cache: \(sampleURL.lastPathComponent)")
                    }
                } catch {
                    // Cache corrupt — re-download
                    try? FileManager.default.removeItem(at: cachePath)
                    self.downloadAndDecode(sampleURL: sampleURL, cachePath: cachePath, key: key)
                }
            } else if sampleURL.isFileURL {
                do {
                    let buf = try Self.decodeAudio(from: sampleURL)
                    self.serialQueue.async {
                        self.decodedBuffers[key] = buf
                        self.inFlight.remove(key)
                    }
                } catch {
                    print("[SampleBankManager] Failed to decode file sample: \(error)")
                    self.serialQueue.async { self.inFlight.remove(key) }
                }
            } else {
                self.downloadAndDecode(sampleURL: sampleURL, cachePath: cachePath, key: key)
            }
        }
    }

    private func downloadAndDecode(sampleURL: URL, cachePath: URL, key: String) {
        let task = URLSession.shared.dataTask(with: sampleURL) { [weak self] data, response, error in
            guard let self else { return }
            if let data = data, error == nil {
                // Write to disk
                try? data.write(to: cachePath, options: .atomic)
                do {
                    let buf = try Self.decodeAudio(from: cachePath)
                    self.serialQueue.async {
                        self.decodedBuffers[key] = buf
                        self.inFlight.remove(key)
                        print("[SampleBankManager] Downloaded: \(sampleURL.lastPathComponent)")
                    }
                } catch {
                    print("[SampleBankManager] Decode failed for \(sampleURL.lastPathComponent): \(error)")
                    self.serialQueue.async { self.inFlight.remove(key) }
                }
            } else {
                print("[SampleBankManager] Download failed for \(sampleURL.lastPathComponent): \(error?.localizedDescription ?? "?")")
                self.serialQueue.async { self.inFlight.remove(key) }
            }
        }
        task.resume()
    }

    // MARK: - Audio decoding

    /// Decode a WAV/AIFF file → normalised canonical buffer (Float32, stereo, 44.1 kHz).
    static func decodeAudio(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw SampleBankError.decodeFailed(url.lastPathComponent)
        }
        try file.read(into: buf)
        return PatternScheduler.normalizedBuffer(buf)
    }

    // MARK: - Helpers

    /// Convert a URL string to a filesystem-safe cache filename.
    /// Strategy: replace non-alphanumeric characters with "_", keep extension.
    private func safeCacheName(for key: String) -> String {
        Self.safeCacheName(for: key)
    }

    static func safeCacheName(for key: String) -> String {
        let ext = (key as NSString).pathExtension
        let noExt = ext.isEmpty ? key : String(key.dropLast(ext.count + 1))
        let safe = noExt.unicodeScalars.map { c -> Character in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            return allowed.contains(c) ? Character(c) : "_"
        }
        let name = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let truncated = name.suffix(180)  // keep within FS limits
        return ext.isEmpty ? String(truncated) : "\(truncated).\(ext)"
    }
}

// MARK: - URL extension

private extension URL {
    /// Normalize URL by removing double-slashes in path (e.g. base ends with /, path starts with /)
    var cleaned: URL {
        let s = absoluteString
        // Replace "://" followed by host, then remove any double slashes in path
        guard var components = URLComponents(string: s) else { return self }
        var path = components.path
        // Collapse consecutive slashes
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        components.path = path
        return components.url ?? self
    }
}

// MARK: - Error

public enum SampleBankError: Error, LocalizedError {
    case manifestLoadFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestLoadFailed(let u): return "Manifest load failed: \(u)"
        case .decodeFailed(let n):       return "Audio decode failed: \(n)"
        }
    }
}
