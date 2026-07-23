// ---------------------------------------------------------------------------
// Signal.swift — Continuous signal patterns (P0-2: infraestructura EEG para Eno)
//
// Una señal continua es un Pattern<Double> SIN estructura discreta:
//   - whole = nil  (los haps analógicos no tienen estructura discreta)
//   - value = f(span.begin)  ← evaluado en el INICIO del span consultado
//
// Semántica confirmada contra oracle (strudel.cc black-box):
//   signal(f) devuelve UNO hap por query cuyo valor es f(span.begin), whole=nil
//   sine(0) = 0.5, sine(0.25) = 1.0 (fase confirmada)
//   segment(n): discretiza en n haps por ciclo, cada uno con whole=part=[k/n,(k+1)/n)
//   gain(sine): señal evaluada en whole.begin del evento discreto (appLeft semántica)
//
// CLEAN-ROOM: implementado desde documentación pública strudel.cc/learn.
// La equivalencia bit-a-bit es exacta para sine/saw/tri/square/isaw/cosine.
// Para rand: la distribución es uniforme [0,1) pero la secuencia exacta
//   difiere de Strudel (distintos algoritmos de hash). Documentado.
// Para perlin: interpolación suave entre valores rand por ciclo.
//   Concepto de dominio público; equivalencia aproximada documentada.
// ---------------------------------------------------------------------------

import Foundation

// MARK: - signal() constructor

/// Creates a continuous signal pattern.
///
/// A signal is a Pattern<Double> with no discrete structure:
/// - Each query returns ONE hap whose value is f(span.begin)
/// - whole = nil (continuous, no discrete onset)
/// - Sampling point: the BEGIN of the queried span (confirmed against oracle)
///
/// This is the EEG hook: `signal { t in eegFeature(t) }` injects any
/// real-time value as a continuous control pattern.
///
/// Note: from CodeParser (editor), signal() with an external callback has
/// no syntax — it is a Swift-only API. Signal expressions in the editor
/// use the named oscillators (sine, saw, etc.) with .range/.slow/.fast chains.
public func signal(_ f: @escaping (Double) -> Double) -> Pattern<Double> {
    Pattern { span in
        let t = span.begin.toDouble
        return [Hap(whole: nil, part: span, value: f(t))]
    }
}

// MARK: - Oscillators (public Strudel API — strudel.cc/learn/signals)

/// Sawtooth signal 0..1, rising within each cycle.
/// saw(t) = t mod 1. At t=0: 0, at t=0.5: 0.5, at t=1: 0 (wraps).
/// Confirmed against oracle: saw.range(2,4).segment(4) → [2, 2.5, 3, 3.5]
public let saw: Pattern<Double> = signal { t in
    t.truncatingRemainder(dividingBy: 1.0)
}

/// Inverse sawtooth signal 1..0, falling within each cycle.
/// isaw(t) = 1 - (t mod 1). At t=0: 1, at t=0.5: 0.5.
public let isaw: Pattern<Double> = signal { t in
    1.0 - t.truncatingRemainder(dividingBy: 1.0)
}

/// Sine signal 0..1.
/// sine(t) = (sin(2π·t) + 1) / 2
/// Phase confirmed against oracle:
///   sine(t=0) = 0.5 (rises from center)
///   sine(t=0.25) = 1.0 (peak at quarter cycle)
///   sine(t=0.5)  = 0.5 (back to center)
///   sine(t=0.75) = 0.0 (trough)
public let sine: Pattern<Double> = signal { t in
    (sin(2.0 * .pi * t) + 1.0) / 2.0
}

/// Cosine signal 0..1. Like sine but phase-shifted 1/4 cycle early.
/// cosine(t) = sine(t + 0.25) = (cos(2π·t) + 1) / 2
/// At t=0: 1.0, at t=0.25: 0.5.
public let cosine: Pattern<Double> = signal { t in
    (cos(2.0 * .pi * t) + 1.0) / 2.0
}

/// Square signal 0..1. Low for first half-cycle, high for second half.
/// square(t) = floor((t * 2) mod 2)
/// Semantics confirmed: square(0) = 0, square(0.5) = 1.
public let square: Pattern<Double> = signal { t in
    floor((t * 2.0).truncatingRemainder(dividingBy: 2.0))
}

/// Triangle signal 0..1. Rises 0→1 in first half-cycle, falls 1→0 in second.
/// Implemented as fastcat(saw, isaw) matching Strudel's public definition.
/// This means: first half-cycle is saw (0→1), second half is isaw (1→0).
public let tri: Pattern<Double> = fastcat(saw, isaw)

/// Deterministic pseudo-random signal 0..1.
///
/// Each distinct time value maps to a stable pseudo-random number via a
/// hash of the time. The sequence is deterministic (same t → same value)
/// and seeded with a fixed constant.
///
/// APPROXIMATION DOCUMENTED: the exact sequence differs from Strudel's
/// `rand` (which uses legacy xorshift + murmur hash keyed on t*536870912).
/// Distribution is uniform [0,1). For EEG use, the exact bit sequence is
/// irrelevant — only distribution matters.
public let rand: Pattern<Double> = signal { t in
    _randAtTime(t)
}

/// Smooth perlin-style noise 0..1.
///
/// Interpolates between stable pseudo-random values at integer cycle
/// boundaries, producing smooth continuous variation.
/// Concept: public-domain Perlin noise (1-D value noise variant).
///
/// APPROXIMATION DOCUMENTED: Strudel's `perlin` uses a different hash
/// function (murmur-based). This implementation uses the same _randAtTime
/// hash but with cubic Hermite interpolation between cycle-boundary values.
/// The shape is smooth and bounded [0,1); exact values differ from Strudel.
public let perlin: Pattern<Double> = signal { t in
    _perlinAtTime(t)
}

// MARK: - Signal methods (range, rangex, segment)

extension Pattern where T == Double {

    /// Scale a unipolar 0..1 signal to [min, max].
    /// Confirmed against oracle: saw.range(2,4) at t=0 → 2.0, at t=0.5 → 3.0.
    public func range(_ minVal: Double, _ maxVal: Double) -> Pattern<Double> {
        map { v in v * (maxVal - minVal) + minVal }
    }

    /// Scale a unipolar 0..1 signal to [min, max] on an exponential curve.
    /// rangex(min, max): maps 0..1 → exp(log(min)..log(max))
    /// Useful for frequency ranges (e.g. lpf.rangex(200, 4000)).
    /// min and max must be > 0.
    public func rangex(_ minVal: Double, _ maxVal: Double) -> Pattern<Double> {
        map { v in exp(v * log(maxVal / minVal) + log(minVal)) }
    }

    /// Discretize a continuous signal into n equal samples per cycle.
    ///
    /// Creates n haps per cycle. Each hap k:
    ///   part = whole = [cycleN + k/n, cycleN + (k+1)/n)
    ///   value = signal sampled at t = cycleN + k/n (begin of the slot)
    ///
    /// This matches Strudel's public semantics (confirmed against oracle):
    ///   sine.segment(8): hap[0] part=[0/1,1/8), value=0.5 (sin(0)=0.5)
    ///   saw.range(2,4).segment(4): [2.0, 2.5, 3.0, 3.5]
    public func segment(_ n: Int) -> Pattern<Double> {
        guard n > 0 else { return .silence }
        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let rCycle = Rational(cycleN)
            var haps: [Hap<Double>] = []
            for k in 0..<n {
                let slotBegin = rCycle + Rational(k, n)
                let slotEnd   = rCycle + Rational(k + 1, n)
                let slotSpan  = TimeSpan(slotBegin, slotEnd)
                guard let partSpan = slotSpan.intersection(span) else { continue }
                // Sample signal at the begin of the slot (confirmed oracle semantics)
                let sampleSpan = TimeSpan(slotBegin, slotEnd)
                let value = self.query(sampleSpan).first?.value ?? 0.0
                haps.append(Hap(whole: slotSpan, part: partSpan, value: value))
            }
            return haps
        })
    }
}

// MARK: - Conversion: Pattern<Double> → ControlPattern

extension Pattern where T == Double {
    /// Convert a signal to a ControlPattern with the given control key.
    /// Used internally by gain(_:Pattern<Double>), lpf(_:Pattern<Double>), etc.
    public func asControl(_ key: String) -> Pattern<[String: ControlValue]> {
        map { v in [key: .double(v)] }
    }
}

// MARK: - Private hash functions

/// Deterministic hash of a Double time value → uniform [0, 1).
/// Uses integer conversion at 1/2^29 resolution (same granularity as Strudel's
/// legacy RNG internal representation) with a splitmix64-style finalizer.
/// This is a custom hash — the output sequence differs from Strudel's rand.
func _randAtTime(_ t: Double) -> Double {
    // Convert time to integer at fine resolution
    var x = UInt64(bitPattern: Int64(t * 536870912.0))
    // splitmix64 finalizer (public domain)
    x = x &+ 0x9E3779B97F4A7C15
    x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
    x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
    x = x ^ (x >> 31)
    return Double(x) / Double(UInt64.max)
}

/// Smooth value noise at time t. Cubic Hermite interpolation between
/// random values at integer time boundaries.
func _perlinAtTime(_ t: Double) -> Double {
    let t0 = floor(t)
    let t1 = t0 + 1.0
    let frac = t - t0
    let v0 = _randAtTime(t0)
    let v1 = _randAtTime(t1)
    // Cubic Hermite smoothstep: 3f² − 2f³
    let smooth = frac * frac * (3.0 - 2.0 * frac)
    return v0 + smooth * (v1 - v0)
}
