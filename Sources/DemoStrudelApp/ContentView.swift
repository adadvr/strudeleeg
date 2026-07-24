import SwiftUI
import MiniEngine

// ---------------------------------------------------------------------------
// Seed code — identical in both editors (from devstrudeleeg.md brief)
// ---------------------------------------------------------------------------
private let seedCode = """
stack(
  s("pad").slow(4).gain(0.5).room(0.6),
  note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
)
"""

// ---------------------------------------------------------------------------
// ContentView — two-panel A/B layout
// ---------------------------------------------------------------------------
struct ContentView: View {

    // Engine state
    @StateObject private var vm = DemoViewModel()

    // Editor text (three independent bindings, same initial content)
    @State private var leftCode  = seedCode
    @State private var rightCode = seedCode
    @State private var juceCode  = seedCode

    // Estado de presets
    @State private var presets: [SongPreset] = PresetStore.all()
    @State private var selectedPresetID: String? = nil
    @State private var newTemplateName: String = ""
    @State private var guardadoVisible: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Barra de presets ─────────────────────────────────────────
            presetBar

            Divider()

            // ── Three panels: Strudel · Mini Engine · JUCE ──────────────
            HSplitView {
                leftPanel
                rightPanel
                jucePanel
            }
            .frame(minHeight: 480)

            Divider()

            // ── Barra inferior: Stop + timer ─────────────────────────────
            HStack(spacing: 20) {
                Spacer()

                // Timer de audio — visible solo cuando hay reproducción activa
                if vm.lastPlayedSide != .none {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundColor(.secondary)
                        Text(vm.elapsedString)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }

                Button {
                    vm.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: [.command])

                Spacer()
            }
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1400, minHeight: 600)
    }

    // ── Barra de presets — selector + guardar template ───────────────────
    private var presetBar: some View {
        HStack(spacing: 12) {
            Label("Presets", systemImage: "music.note.list")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            Picker("Template", selection: $selectedPresetID) {
                Text("— elegir —").tag(String?.none)
                ForEach(presets) { preset in
                    Text(preset.name).tag(String?.some(preset.id))
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 240)
            .onChange(of: selectedPresetID) { _, newID in
                // Al seleccionar, cargamos el código en los tres editores
                guard let id = newID,
                      let preset = presets.first(where: { $0.id == id }) else { return }
                leftCode  = preset.code
                rightCode = preset.code
                juceCode  = preset.code
            }

            Divider()
                .frame(height: 20)

            // Campo y botón para guardar template de usuario
            TextField("Nombre del template", text: $newTemplateName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 260)

            Button {
                guard !newTemplateName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                if let saved = try? PresetStore.save(name: newTemplateName, code: leftCode) {
                    presets = PresetStore.all()
                    selectedPresetID = saved.id
                    newTemplateName = ""
                    // Mostrar confirmación temporal
                    guardadoVisible = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guardadoVisible = false
                    }
                }
            } label: {
                Label("Guardar template", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
            .disabled(newTemplateName.trimmingCharacters(in: .whitespaces).isEmpty)

            // Confirmación temporal de guardado
            if guardadoVisible {
                Text("Guardado ✓")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // ── Left panel — Motor A (Strudel / WebView) ─────────────────────────
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader(
                title: "Strudel",
                subtitle: "WebView · WebAudio",
                systemImage: "globe",
                color: .blue,
                isPlaying: vm.lastPlayedSide == .left
            )

            codeEditor(text: $leftCode)

            Button {
                vm.playStrudel(code: leftCode)
            } label: {
                playButtonLabel(isActive: vm.lastPlayedSide == .left)
            }
            .buttonStyle(PlayButtonStyle(color: .blue, isActive: vm.lastPlayedSide == .left))

            if !vm.strudelError.isEmpty && vm.lastPlayedSide == .left {
                Text(vm.strudelError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            } else if !vm.statusMessage.isEmpty && vm.lastPlayedSide == .left {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }

    // ── Right panel — Motor B (NativeEngine / AVAudioEngine) ─────────────
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader(
                title: "Mini Engine",
                subtitle: "Swift · AVAudioEngine",
                systemImage: "waveform",
                color: .green,
                isPlaying: vm.lastPlayedSide == .right
            )

            codeEditor(text: $rightCode)

            Button {
                vm.playNative(code: rightCode)
            } label: {
                playButtonLabel(isActive: vm.lastPlayedSide == .right)
            }
            .buttonStyle(PlayButtonStyle(color: .green, isActive: vm.lastPlayedSide == .right))

            if !vm.parseError.isEmpty && vm.lastPlayedSide == .right {
                Text(vm.parseError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            } else if !vm.statusMessage.isEmpty && vm.lastPlayedSide == .right {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }

    // ── Third panel — Motor C (JUCE / juce::dsp) ─────────────────────────
    private var jucePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader(
                title: "JUCE Engine",
                subtitle: "C++ · juce::dsp (synths + samples · FX en progreso)",
                systemImage: "cpu",
                color: .orange,
                isPlaying: vm.lastPlayedSide == .juce
            )

            codeEditor(text: $juceCode)

            Button {
                vm.playJuce(code: juceCode)
            } label: {
                playButtonLabel(isActive: vm.lastPlayedSide == .juce)
            }
            .buttonStyle(PlayButtonStyle(color: .orange, isActive: vm.lastPlayedSide == .juce))

            if !vm.statusMessage.isEmpty && vm.lastPlayedSide == .juce {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }

    // ── Shared helpers ────────────────────────────────────────────────────

    private func panelHeader(
        title: String,
        subtitle: String,
        systemImage: String,
        color: Color,
        isPlaying: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(color)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if isPlaying {
                Spacer()
                // Active indicator dot
                HStack(spacing: 4) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text("Sonando")
                        .font(.caption2)
                        .foregroundColor(color)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func codeEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .frame(minHeight: 200)
    }

    private func playButtonLabel(isActive: Bool) -> some View {
        Label(isActive ? "Reproduciendo..." : "Play", systemImage: "play.fill")
            .font(.system(size: 15, weight: .semibold))
    }
}

// ---------------------------------------------------------------------------
// PlayButtonStyle — brighter when this side is actively playing
// ---------------------------------------------------------------------------
struct PlayButtonStyle: ButtonStyle {
    let color: Color
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 9)
            .background(
                color.opacity(
                    isActive
                        ? (configuration.isPressed ? 0.95 : 1.0)   // fully saturated when playing
                        : (configuration.isPressed ? 0.55 : 0.75)  // dimmed when idle
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? color : Color.clear, lineWidth: 2)
            )
    }
}

// ---------------------------------------------------------------------------
// DemoViewModel — holds engine references and state
// ---------------------------------------------------------------------------
enum PlaySide { case left, right, juce, none }

@MainActor
final class DemoViewModel: ObservableObject {

    @Published var statusMessage: String = ""
    @Published var parseError: String = ""
    @Published var strudelError: String = ""
    @Published var lastPlayedSide: PlaySide = .none

    // ── Timer de audio ───────────────────────────────────────────────────
    @Published var elapsed: TimeInterval = 0
    private var audioTimer: Timer?
    private var playStartDate: Date?

    /// Cadena formateada "m:ss.d" para mostrar en la UI (ej. "1:23.4").
    var elapsedString: String {
        let total = elapsed
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let tenths  = Int((total * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    /// Arranca (o reinicia) el timer de posición de reproducción.
    private func startTimer() {
        audioTimer?.invalidate()
        playStartDate = Date()
        elapsed = 0
        // Capturamos la fecha de inicio como valor local para evitar
        // acceder a la propiedad aislada en @MainActor desde un closure Sendable.
        let startDate = playStartDate!
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let now = Date().timeIntervalSince(startDate)
            Task { @MainActor [weak self] in
                self?.elapsed = now
            }
        }
    }

    /// Detiene el timer y resetea el contador.
    private func stopTimer() {
        audioTimer?.invalidate()
        audioTimer = nil
        playStartDate = nil
        elapsed = 0
    }

    private let nativeEngine: NativeEngineAdapter
    private let strudelEngine: StrudelWebEngine
    private let juceEngine: JuceEngine
    private let juceScheduler: JucePatternScheduler

    init() {
        self.nativeEngine = NativeEngineAdapter()
        self.strudelEngine = StrudelWebEngine()
        let je = JuceEngine()
        self.juceEngine = je
        self.juceScheduler = JucePatternScheduler(engine: je, sampleURLs: bundleSampleURLs())

        // Registrar el directorio de soundfonts bundleados para acceso offline
        // e instantáneo (sin descarga). Se usa AppBundle.resources en lugar de
        // Bundle.main para que funcione tanto en swift run/debug como en .app
        // distribuido (ver AppBundle.swift — resuelve el bundle SPM correctamente).
        if let sfDir = AppBundle.resources.url(forResource: "Soundfonts", withExtension: nil) {
            SoundfontManager.shared.addLocalDirectory(sfDir)
        }

        self.nativeEngine.onParseError = { [weak self] msg in
            Task { @MainActor in
                self?.parseError = msg
            }
        }

        self.juceScheduler.onParseError = { [weak self] msg in
            Task { @MainActor in
                self?.parseError = msg
            }
        }

        self.strudelEngine.onError = { [weak self] msg in
            Task { @MainActor in
                self?.strudelError = msg
            }
        }

        self.strudelEngine.onStatusChange = { [weak self] status in
            Task { @MainActor in
                if status == "playing" {
                    self?.statusMessage = "Reproduciendo Strudel (WebAudio)…"
                } else if status == "stopped" {
                    self?.statusMessage = ""
                }
            }
        }
    }

    func playStrudel(code: String) {
        strudelEngine.stop()          // stop current if any
        nativeEngine.stop()           // stop the other engine for clean A/B
        juceScheduler.stop()
        lastPlayedSide = .left
        strudelError = ""
        statusMessage = "Iniciando Strudel…"
        strudelEngine.play(code: code)
        startTimer()
    }

    func playNative(code: String) {
        nativeEngine.stop()           // stop previous if playing
        strudelEngine.stop()          // stop the other engine for clean A/B
        juceEngine.stop()
        lastPlayedSide = .right
        parseError = ""
        statusMessage = "Reproduciendo Motor B…"

        // Validar antes de reproducir — nunca impide la reproducción
        let diags = CodeParser().validate(code)
        if !diags.isEmpty {
            parseError = formatDiagnostics(diags)
        }

        nativeEngine.play(code: code)
        startTimer()
    }

    /// Fase 2: JUCE reproduce voces de synth reales del patrón (samples/FX en
    /// Fases 3-4). Reutiliza el motor de patrones Swift vía JucePatternScheduler.
    func playJuce(code: String) {
        nativeEngine.stop()
        strudelEngine.stop()
        juceScheduler.stop()
        lastPlayedSide = .juce
        parseError = ""
        statusMessage = "Reproduciendo JUCE (synths + samples · FX en progreso)"

        // Validar antes de reproducir — nunca impide la reproducción
        let diags = CodeParser().validate(code)
        if !diags.isEmpty {
            parseError = formatDiagnostics(diags)
        }

        juceScheduler.play(code: code)
        startTimer()
    }

    /// Formatea una lista de diagnósticos en texto legible multi-línea (en español).
    private func formatDiagnostics(_ diags: [PatternDiagnostic]) -> String {
        diags.map { diag in
            let prefix: String
            switch diag.kind {
            case .arbitraryJS:
                prefix = "⚠ Línea \(diag.line): JavaScript no soportado"
            case .unsupported:
                prefix = "⚠ Línea \(diag.line): `\(diag.token)` no soportado"
            case .info:
                prefix = "ℹ Línea \(diag.line): \(diag.token)"
            }
            if let sug = diag.suggestion {
                return "\(prefix) — \(sug)"
            }
            return prefix
        }.joined(separator: "\n")
    }

    func stopAll() {
        nativeEngine.stop()
        strudelEngine.stop()
        juceScheduler.stop()
        stopTimer()
        statusMessage = ""
        strudelError = ""
        parseError = ""
        lastPlayedSide = .none
    }
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------
#Preview {
    ContentView()
}
