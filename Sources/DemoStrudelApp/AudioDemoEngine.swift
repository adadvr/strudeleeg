import Foundation

/// Common protocol for both audio engines used in the demo.
/// Motor A (StrudelWebEngine) and Motor B (NativeEngine) both conform to this.
public protocol AudioDemoEngine {
    /// Start playback interpreting the given Strudel-subset code.
    func play(code: String)
    /// Stop all playback immediately.
    func stop()
}
