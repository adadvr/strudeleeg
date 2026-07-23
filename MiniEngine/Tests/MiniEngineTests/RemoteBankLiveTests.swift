import XCTest
import AVFoundation
@testable import MiniEngine

final class RemoteBankLiveTests: XCTestCase {

    /// Salta el test si no hay red (los tests unitarios de SampleBankTests
    /// cubren la lógica sin red; este es el end-to-end real contra GitHub).
    private func requireNetwork() throws {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var req = URLRequest(url: URL(string: "https://raw.githubusercontent.com")!)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = resp != nil
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        try XCTSkipUnless(ok, "sin red — se salta el test remoto en vivo")
    }

    func testRemoteAcceptancePattern() throws {
        try requireNetwork()
        let code = """
        samples('github:tidalcycles/dirt-samples')
        stack(
          s("tabla:0 ~ ~ tabla:3 ~ ~ tabla:1 ~").gain(0.35),
          s("wind").gain(0.12).room(0.9),
          note("g#4 ~ a4 g#4").s("sitar").gain(0.4).room(0.45)
        )
        """
        let engine = MiniEngine(sampleURLs: [:])
        var captured: [Float] = []
        let lock = NSLock()
        engine.play(code: code)
        let av = engine.audioEngineForTesting
        let fmt = av.mainMixerNode.outputFormat(forBus: 0)
        av.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
            lock.lock(); defer { lock.unlock() }
            if let ch = buf.floatChannelData?[0] {
                captured.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            }
        }
        // dejar tiempo a descarga (primera vez) + al menos un ciclo de audio
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 8.0))
        av.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let samples = captured; lock.unlock()
        let rms = sqrt(samples.map{Double($0*$0)}.reduce(0,+)/Double(max(1,samples.count)))
        print("=== REMOTE RMS:", rms, "samples:", samples.count)
        XCTAssertGreaterThan(rms, 0.005, "el patrón remoto no produjo audio")
    }
}
