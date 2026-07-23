// WebProbe — sonda headless para diagnosticar el Motor A sin abrir la app.
// Carga StrudelWeb/index.html igual que StrudelWebEngine, llama strudelPlay y
// luego reporta: estado del AudioContext, si fetch(file://...wav) funciona,
// y el contenido de los divs de status/error de la página.
//
// Modos:
//   swift run WebProbe <resourceBundleDir> [--allow-file]
//   swift run WebProbe <resourceBundleDir> --record '<código>' <segundos> <salida.raw>
//
// Modo --record:
//   Inyecta un WKUserScript en .atDocumentStart que parchea AudioNode.prototype.connect:
//   cualquier nodo que conecte a ctx.destination también se conecta a un capturador
//   ScriptProcessorNode(4096, 2, 2) cuyo onaudioprocess acumula los samples en
//   window.__capture. Tras N segundos extrae los samples (base64 de Float32Array
//   por chunks) y escribe el .raw (float32 mono, little-endian).

import AppKit
import WebKit
import Foundation

// MARK: - Argument parsing

let args = CommandLine.arguments
guard args.count > 1 else {
    print("uso: WebProbe <resourceBundleDir> [--allow-file] [--no-throttle]")
    print("     WebProbe <resourceBundleDir> --record '<código>' <segundos> <salida.raw>")
    exit(2)
}

let bundleDir = URL(fileURLWithPath: args[1])
let allowFile = args.contains("--allow-file")
let noThrottle = args.contains("--no-throttle")

// Detect --record mode
let recordMode: Bool
var recordCode: String = ""
var recordSeconds: Double = 3.0
var recordOutput: String = "/tmp/webprobe_record.raw"

if let ri = args.firstIndex(of: "--record") {
    guard ri + 3 < args.count else {
        print("uso --record: WebProbe <bundleDir> --record '<código>' <segundos> <salida.raw>")
        exit(2)
    }
    recordMode = true
    recordCode    = args[ri + 1]
    recordSeconds = Double(args[ri + 2]) ?? 3.0
    recordOutput  = args[ri + 3]
} else {
    recordMode = false
}

let indexURL = bundleDir.appendingPathComponent("StrudelWeb/index.html")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// MARK: - WKWebViewConfiguration

let config = WKWebViewConfiguration()
config.mediaTypesRequiringUserActionForPlayback = []

if allowFile || recordMode {
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
}

// Always disable throttling so audio timer runs at full rate
config.preferences.setValue(false, forKey: "hiddenPageDOMTimerThrottlingEnabled")
config.preferences.setValue(false, forKey: "pageVisibilityBasedProcessSuppressionEnabled")

// MARK: - Audio capture monkey-patch (injected BEFORE strudel-bundle.js)
//
// WKUserScript con .atDocumentStart se ejecuta ANTES de que cualquier <script>
// de la página se evalúe — esto incluye strudel-bundle.js.  Eso nos da tiempo
// de parchar AudioNode.prototype.connect antes de que superdough lo use.
//
// Estrategia:
//   1. Parchamos AudioNode.prototype.connect.
//   2. Cuando un nodo conecta a ctx.destination, creamos (lazy, una sola vez)
//      un ScriptProcessorNode(4096, 2, 2) adjunto al mismo AudioContext.
//   3. El nodo fuente se conecta tanto a destination como al capturador.
//   4. El capturador conecta a un GainNode(0) → destination para mantenerse activo.
//   5. onaudioprocess copia inputBuffer.getChannelData(0) (L) a window.__captureChunks.
//   6. window.__captureReady (Promise) se resuelve cuando llamamos
//      window.__captureStop() desde Swift.

let captureScript = """
(function() {
    'use strict';

    // Estado del capturador — uno por AudioContext (lazy)
    window.__captureChunks = [];
    window.__captureSampleRate = 0;
    window.__captureActive = false;

    // Patch AudioNode.prototype.connect
    const _origConnect = AudioNode.prototype.connect;
    AudioNode.prototype.connect = function(dest, outCh, inCh) {
        // Llamar siempre al connect original primero
        const result = arguments.length === 1
            ? _origConnect.call(this, dest)
            : arguments.length === 2
                ? _origConnect.call(this, dest, outCh)
                : _origConnect.call(this, dest, outCh, inCh);

        // Solo nos interesa cuando el destino es el AudioDestinationNode
        try {
            const ctx = this.context;
            if (dest === ctx.destination && ctx && !ctx.__captureSetup) {
                ctx.__captureSetup = true;
                window.__captureSampleRate = ctx.sampleRate;
                window.__captureActive = true;

                // ScriptProcessorNode: bufferSize=4096, inputs=2, outputs=2
                // Deprecated pero funcional en WebKit (WKWebView).
                const proc = ctx.createScriptProcessor(4096, 2, 2);

                proc.onaudioprocess = function(ev) {
                    if (!window.__captureActive) return;
                    const data = ev.inputBuffer.getChannelData(0); // canal L, mono
                    // Copiar a un nuevo Float32Array para persistir (la data del evento
                    // se recicla por el runtime tras el callback)
                    const chunk = new Float32Array(data.length);
                    chunk.set(data);
                    window.__captureChunks.push(chunk);
                };

                // Conectar: nodo fuente → proc → silentGain → destination
                // El silentGain(0) suprime el audio del loop de captura.
                const silentGain = ctx.createGain();
                silentGain.gain.value = 0;

                this.connect(proc);     // ya tiene el result del connect original
                proc.connect(silentGain);
                silentGain.connect(ctx.destination);
            }
        } catch (e) {
            // Ignorar errores del patch — no debe romper el audio principal
            console.warn('[WebProbe capture] patch error:', e);
        }

        return result;
    };

    // __captureStop: congela la captura y devuelve info básica
    window.__captureStop = function() {
        window.__captureActive = false;
        return {
            chunks: window.__captureChunks.length,
            sampleRate: window.__captureSampleRate
        };
    };

    console.log('[WebProbe] AudioNode.prototype.connect patched for capture');
})();
"""

// MARK: - Inject capture script at document start (before any page JS)
if recordMode {
    let userScript = WKUserScript(
        source: captureScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
    config.userContentController.addUserScript(userScript)
}

let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)

// We need a visible window for audio to work in WKWebView (macOS requirement)
let win = NSWindow(
    contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
win.contentView = wv
win.orderFront(nil)   // must be ordered to a screen for audio to work

// MARK: - Helpers

/// Compute RMS of Float32 samples, skipping the first `warmupSec` seconds.
func computeRMS(samples: [Float], sampleRate: Double, warmupSec: Double = 0.3) -> Double {
    let skip = Int(warmupSec * sampleRate)
    let slice = samples.dropFirst(skip)
    guard slice.count > 0 else { return 0.0 }
    let sumSq = slice.reduce(0.0) { $0 + Double($1 * $1) }
    return sqrt(sumSq / Double(slice.count))
}

// MARK: - Navigation delegate

final class ProbeDelegate: NSObject, WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if recordMode {
            handleRecordMode(webView: webView)
        } else {
            handleDiagnoseMode(webView: webView)
        }
    }

    // MARK: Record mode

    func handleRecordMode(webView: WKWebView) {
        print("[probe] index.html cargado. Modo --record activado.")
        print("[probe] Esperando init de Strudel (4s)…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            // Resume AudioContext + play
            let playJS: String
            do {
                let encoded = try JSONSerialization.data(withJSONObject: recordCode, options: [.fragmentsAllowed])
                let encodedStr = String(data: encoded, encoding: .utf8)!
                // callAsyncJavaScript: body = interior de async function, usar await/return directamente
                playJS = """
                try {
                    var getCtx = window.__strudelExports && window.__strudelExports.getAudioContext;
                    if (getCtx) {
                        var ctx = getCtx();
                        if (ctx && ctx.state !== 'running') await ctx.resume();
                    }
                } catch(_) {}
                await window.strudelPlay(\(encodedStr));
                return 'play_ok';
                """
            } catch {
                print("[probe] Error codificando el código: \(error)")
                exit(1)
            }

            print("[probe] Llamando strudelPlay(\"\(recordCode)\")…")
            webView.callAsyncJavaScript(playJS, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v):
                    print("[probe] strudelPlay retornó: \(String(describing: v))")
                case .failure(let e):
                    print("[probe] ERROR strudelPlay: \(e.localizedDescription)")
                }
            }

            // Grabar durante recordSeconds, luego extraer
            let waitSecs = recordSeconds + 0.5   // pequeño margen
            print("[probe] Grabando \(recordSeconds)s… (total espera: \(waitSecs)s)")
            DispatchQueue.main.asyncAfter(deadline: .now() + waitSecs) {
                self.extractAndSave(webView: webView)
            }
        }
    }

    func extractAndSave(webView: WKWebView) {
        print("[probe] Deteniendo captura y extrayendo samples…")

        // Paso 1: detener captura y saber cuántos chunks hay
        // callAsyncJavaScript: el body es el interior de una función async — usar return directamente.
        let stopJS = """
        var info = window.__captureStop();
        return JSON.stringify(info);
        """
        webView.callAsyncJavaScript(stopJS, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let e):
                print("[probe] ERROR __captureStop: \(e.localizedDescription)")
                exit(1)
            case .success(let v):
                guard let jsonStr = v as? String,
                      let data = jsonStr.data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    print("[probe] No se pudo parsear info de captura: \(String(describing: v))")
                    exit(1)
                }
                let chunks = info["chunks"] as? Int ?? 0
                let sr = info["sampleRate"] as? Double ?? 44100.0
                print("[probe] Captura detenida: \(chunks) chunks, sampleRate=\(sr) Hz")

                if chunks == 0 {
                    print("[probe] ADVERTENCIA: 0 chunks — el patch de AudioContext no interceptó ninguna conexión.")
                    print("[probe] Posible causa: el AudioContext ya estaba creado antes del script de inicio,")
                    print("[probe] o Strudel no emitió audio durante la grabación.")
                    // Escribir archivo vacío para indicar error
                    let emptyData = Data()
                    try? emptyData.write(to: URL(fileURLWithPath: recordOutput))
                    print("[probe] Archivo vacío escrito en: \(recordOutput)")
                    print("[probe] RMS: 0.0 (sin datos)")
                    exit(1)
                }

                self.extractChunks(webView: webView, totalChunks: chunks, sampleRate: sr)
            }
        }
    }

    // Extrae chunks de JS a Swift en lotes de 50 para evitar límites de tamaño de mensaje
    func extractChunks(webView: WKWebView, totalChunks: Int, sampleRate: Double) {
        var allSamples: [Float] = []
        let batchSize = 50   // 50 chunks × 4096 samples = 204800 frames por lote
        var batchStart = 0

        func extractBatch() {
            guard batchStart < totalChunks else {
                // Todos los chunks extraídos — guardar y reportar
                saveAndReport(samples: allSamples, sampleRate: sampleRate)
                return
            }
            let batchEnd = min(batchStart + batchSize, totalChunks)
            // callAsyncJavaScript: body = interior de async function, usar return directamente
            let extractJS = """
            var chunks = window.__captureChunks.slice(\(batchStart), \(batchEnd));
            var total = chunks.reduce(function(s, c) { return s + c.length; }, 0);
            var merged = new Float32Array(total);
            var off = 0;
            for (var i = 0; i < chunks.length; i++) {
                merged.set(chunks[i], off);
                off += chunks[i].length;
            }
            // Codificar como base64 (4 bytes por sample, little-endian Float32)
            var bytes = new Uint8Array(merged.buffer);
            var b64 = '';
            var CHUNK = 3072; // múltiplo de 3 para base64 sin padding parcial
            for (var i = 0; i < bytes.length; i += CHUNK) {
                var slice = bytes.subarray(i, i + CHUNK);
                var bin = '';
                for (var j = 0; j < slice.length; j++) bin += String.fromCharCode(slice[j]);
                b64 += btoa(bin);
            }
            return b64;
            """

            webView.callAsyncJavaScript(extractJS, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .failure(let e):
                    print("[probe] ERROR extrayendo chunks \(batchStart)..\(batchEnd): \(e.localizedDescription)")
                    exit(1)
                case .success(let v):
                    guard let b64 = v as? String else {
                        print("[probe] ERROR: resultado no es string base64")
                        exit(1)
                    }
                    if let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                        // Convertir bytes → Float32 (little-endian, 4 bytes/sample)
                        let floatCount = decoded.count / 4
                        var batch = [Float](repeating: 0, count: floatCount)
                        decoded.withUnsafeBytes { ptr in
                            let fp = ptr.bindMemory(to: Float.self)
                            for i in 0..<floatCount { batch[i] = fp[i] }
                        }
                        allSamples.append(contentsOf: batch)
                        print("[probe]   Lote \(batchStart)..\(batchEnd): \(floatCount) samples (total acumulado: \(allSamples.count))")
                    } else {
                        print("[probe] ADVERTENCIA: base64 inválido en lote \(batchStart)..\(batchEnd)")
                    }
                    batchStart = batchEnd
                    extractBatch()
                }
            }
        }

        extractBatch()
    }

    func saveAndReport(samples: [Float], sampleRate: Double) {
        // Escribir archivo .raw (float32 mono, little-endian)
        let byteCount = samples.count * MemoryLayout<Float>.size
        var rawData = Data(count: byteCount)
        rawData.withUnsafeMutableBytes { ptr in
            let fp = ptr.bindMemory(to: Float.self)
            for i in 0..<samples.count { fp[i] = samples[i] }
        }

        do {
            try rawData.write(to: URL(fileURLWithPath: recordOutput))
            print("[probe] Archivo guardado: \(recordOutput) (\(samples.count) samples, \(byteCount) bytes)")
        } catch {
            print("[probe] ERROR escribiendo archivo: \(error)")
            exit(1)
        }

        // Calcular y reportar RMS
        let rms = computeRMS(samples: samples, sampleRate: sampleRate, warmupSec: 0.3)
        print("[probe] sampleRate: \(sampleRate) Hz")
        print("[probe] Samples capturados: \(samples.count)")
        print("[probe] Duración grabada: \(String(format: "%.2f", Double(samples.count) / sampleRate))s")
        print("[probe] RMS (sin warmup 0.3s): \(String(format: "%.6f", rms))")
        print("[probe] RMS_dBFS: \(String(format: "%.2f", 20.0 * log10(max(rms, 1e-9)))) dBFS")

        exit(0)
    }

    // MARK: Diagnose mode (original behavior)

    func handleDiagnoseMode(webView: WKWebView) {
        print("[probe] index.html cargado; esperando init de Strudel (4s)…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            // Capturar console.* para ver qué reporta el loader de samples
            let hook = """
            window.__probeLogs = [];
            ['log','warn','error'].forEach(k => {
              const orig = console[k];
              console[k] = (...a) => { window.__probeLogs.push(k + ': ' + a.map(String).join(' ')); orig(...a); };
            });
            undefined;
            """
            webView.evaluateJavaScript(hook) { _, _ in
                // Test 1: bank-based drum pattern (main verification target)
                let drumPattern = #"s("bd*4").bank("tr909")"#
                let drumEncoded = String(data: try! JSONSerialization.data(withJSONObject: drumPattern, options: [.fragmentsAllowed]), encoding: .utf8)!
                webView.evaluateJavaScript("window.strudelPlay(\(drumEncoded)); undefined;") { _, err in
                    if let err { print("[probe] error evaluateJavaScript(drumPlay):", err.localizedDescription) }
                }
                // Test 2: stack pattern
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let stackPattern = #"stack(s("bd*4").dec(0.4).gain(0.95), s("~ cp ~ cp").gain(0.5), s("[hh <hh oh>]*4").dec(0.25).gain(0.35))"#
                    let stackEncoded = String(data: try! JSONSerialization.data(withJSONObject: stackPattern, options: [.fragmentsAllowed]), encoding: .utf8)!
                    webView.evaluateJavaScript("window.strudelPlay(\(stackEncoded)); undefined;") { _, err in
                        if let err { print("[probe] error evaluateJavaScript(stackPlay):", err.localizedDescription) }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.diagnose(webView) }
        }
    }

    func diagnose(_ webView: WKWebView) {
        let body = """
        const r = {};
        r.ready = !!window.strudelReady;
        r.statusDiv = document.getElementById('status').textContent;
        r.errorDiv = document.getElementById('error').textContent;
        try {
          const g = __strudelExports.getAudioContext;
          r.hasGetCtx = !!g;
          if (g) {
            const ctx = g();
            r.ctxState = ctx.state;
            try { await ctx.resume(); r.ctxAfterResume = ctx.state; }
            catch (e) { r.resumeErr = String(e); }
          }
        } catch (e) { r.ctxErr = String(e); }
        try {
          const base = window.__STRUDEL_BASE_URL__ || new URL('../Samples/', location.href).href;
          r.base = base;
          // Check pad.wav (original)
          const resp = await fetch(base + 'pad.wav');
          r.fetchOk = resp.ok;
          r.bytes = (await resp.arrayBuffer()).byteLength;
          // Check drum samples (new)
          const drumChecks = ['bd.wav','sd.wav','hh.wav','oh.wav','cp.wav',
                              'tr909/bd.wav','tr909/sd.wav','tr909/hh.wav',
                              'tr808/bd.wav','tr808/sd.wav'];
          r.drumFetch = {};
          for (const name of drumChecks) {
            try {
              const dr = await fetch(base + name);
              r.drumFetch[name] = dr.ok ? 'OK' : ('HTTP ' + dr.status);
            } catch (e) { r.drumFetch[name] = 'ERR: ' + String(e); }
          }
        } catch (e) { r.fetchErr = String(e); }
        r.logs = window.__probeLogs || [];
        return JSON.stringify(r);
        """
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): print("[probe] RESULT:", value as? String ?? "\(String(describing: value))")
            case .failure(let error): print("[probe] diagnose falló:", error.localizedDescription)
            }
            exit(0)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[probe] provisional navigation falló:", error.localizedDescription)
        exit(1)
    }
}

let delegate = ProbeDelegate()
wv.navigationDelegate = delegate
wv.loadFileURL(indexURL, allowingReadAccessTo: bundleDir)

// Timeout de seguridad
let totalTimeout: Double = recordMode ? (recordSeconds + 60.0) : 30.0
DispatchQueue.main.asyncAfter(deadline: .now() + totalTimeout) {
    print("[probe] TIMEOUT")
    exit(3)
}

app.run()
