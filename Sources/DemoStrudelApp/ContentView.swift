import SwiftUI

// ---------------------------------------------------------------------------
// Seed code — identical in both editors
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

    // Editor text (two independent bindings, same initial content)
    @State private var leftCode  = seedCode
    @State private var rightCode = seedCode

    var body: some View {
        VStack(spacing: 0) {
            // ── Two panels ──────────────────────────────────────────────
            HSplitView {
                leftPanel
                rightPanel
            }
            .frame(minHeight: 480)

            Divider()

            // ── Shared stop button ───────────────────────────────────────
            HStack {
                Spacer()
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
        .frame(minWidth: 1000, minHeight: 600)
    }

    // ── Left panel — Motor A (Strudel / WebView) ─────────────────────────
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader(
                title: "Strudel",
                subtitle: "WebView · WebAudio",
                systemImage: "globe",
                color: .blue
            )

            codeEditor(text: $leftCode)

            Button {
                // Motor A not yet wired (F3). Show placeholder feedback.
                vm.statusMessage = "Motor A se integra en F3 (Strudel WebView)"
            } label: {
                playButtonLabel()
            }
            .buttonStyle(PlayButtonStyle(color: .blue))

            if !vm.statusMessage.isEmpty && vm.lastPlayedSide == .left {
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
                color: .green
            )

            codeEditor(text: $rightCode)

            Button {
                vm.playNative(code: rightCode)
            } label: {
                playButtonLabel()
            }
            .buttonStyle(PlayButtonStyle(color: .green))

            if !vm.statusMessage.isEmpty && vm.lastPlayedSide == .right {
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
        color: Color
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

    private func playButtonLabel() -> some View {
        Label("Play", systemImage: "play.fill")
            .font(.system(size: 15, weight: .semibold))
    }
}

// ---------------------------------------------------------------------------
// PlayButtonStyle
// ---------------------------------------------------------------------------
struct PlayButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 9)
            .background(
                color.opacity(configuration.isPressed ? 0.65 : 0.85)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// ---------------------------------------------------------------------------
// DemoViewModel — holds engine references and state
// ---------------------------------------------------------------------------
enum PlaySide { case left, right, none }

@MainActor
final class DemoViewModel: ObservableObject {

    @Published var statusMessage: String = ""
    @Published var lastPlayedSide: PlaySide = .none

    private let nativeEngine: NativeEngineAdapter

    init() {
        self.nativeEngine = NativeEngineAdapter()
    }

    func playNative(code: String) {
        nativeEngine.stop()           // stop previous if playing
        lastPlayedSide = .right
        statusMessage = "Reproduciendo pad.wav (F0 hello-world)"
        nativeEngine.play(code: code)
    }

    func stopAll() {
        nativeEngine.stop()
        statusMessage = ""
        lastPlayedSide = .none
    }
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------
#Preview {
    ContentView()
}
