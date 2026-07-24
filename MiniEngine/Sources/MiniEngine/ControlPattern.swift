// ---------------------------------------------------------------------------
// ControlPattern — Pattern<[String: ControlValue]>
// Each control (s, note, gain, room, cutoff…) is a pattern of a single-field
// map; they are combined with appLeft so structure comes from the base pattern.
// ---------------------------------------------------------------------------

/// A tagged union for control parameter values.
public enum ControlValue: Hashable, CustomStringConvertible, Sendable {
    case string(String)
    case double(Double)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }

    public var description: String {
        switch self {
        case .string(let s): return s
        case .double(let d): return d.truncatingRemainder(dividingBy: 1) == 0
                              ? "\(Int(d))" : "\(d)"
        }
    }
}

/// A pattern of a dictionary of control values.
public typealias ControlPattern = Pattern<[String: ControlValue]>

// MARK: - Combining control maps

/// Merge two control maps; right-side wins on conflict.
public func mergeControls(_ a: [String: ControlValue], _ b: [String: ControlValue]) -> [String: ControlValue] {
    var result = a
    for (k, v) in b { result[k] = v }
    return result
}

// MARK: - ControlPattern combinators

extension Pattern where T == [String: ControlValue] {
    /// Combine with another ControlPattern: structure comes from SELF (base),
    /// control values from OTHER are merged in.
    ///
    /// Semantics (from Tidal / Strudel docs):
    ///   For each base hap, query the control pattern over the base hap's
    ///   *whole* extent. Each control hap whose whole/part overlaps the base
    ///   hap's whole generates one combined output hap, whose:
    ///     - whole = base hap's whole  (structure from base, NOT from control)
    ///     - part  = intersection of base hap's part and control hap's whole
    ///     - value = mergeControls(base_value, control_value)
    ///
    /// This is what Strudel calls "appLeft" / `<*` in Haskell notation.
    public func withControl(_ other: ControlPattern) -> ControlPattern {
        Pattern { span in
            let baseHaps = self.query(span)
            var result: [Hap<[String: ControlValue]>] = []

            for baseHap in baseHaps {
                // Query control over the base hap's whole structural extent
                let querySpan = baseHap.whole ?? baseHap.part
                let controlHaps = other.query(querySpan)

                for controlHap in controlHaps {
                    // Control hap's "extent" for intersection purposes
                    let controlExtent = controlHap.whole ?? controlHap.part
                    // Part = intersection of base part and control extent
                    guard let newPart = baseHap.part.intersection(controlExtent) else { continue }
                    result.append(Hap(
                        whole: baseHap.whole,  // structure from base
                        part:  newPart,
                        value: mergeControls(baseHap.value, controlHap.value)
                    ))
                }
            }
            return result
        }
    }

    // MARK: - Control method chaining

    public func gain(_ value: Double) -> ControlPattern {
        withControl(.pure(["gain": .double(value)]))
    }

    public func gain(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["gain": .double(Double($0) ?? 1.0)] })
    }

    /// Modulate gain with a continuous signal Pattern<Double>.
    /// The signal is evaluated at each event's onset (whole.begin via appLeft semantics).
    /// Example: .gain(sine) → gain follows a 0..1 sine curve per cycle.
    public func gain(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("gain"))
    }

    public func room(_ value: Double) -> ControlPattern {
        withControl(.pure(["room": .double(value)]))
    }

    public func room(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["room": .double(Double($0) ?? 0.0)] })
    }

    /// Modulate room with a continuous signal Pattern<Double>.
    public func room(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("room"))
    }

    public func cutoff(_ value: Double) -> ControlPattern {
        withControl(.pure(["cutoff": .double(value)]))
    }

    public func cutoff(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["cutoff": .double(Double($0) ?? 20000.0)] })
    }

    /// Modulate cutoff with a continuous signal Pattern<Double>.
    public func cutoff(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("cutoff"))
    }

    public func pan(_ value: Double) -> ControlPattern {
        withControl(.pure(["pan": .double(value)]))
    }

    public func pan(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["pan": .double(Double($0) ?? 0.5)] })
    }

    /// Modulate pan with a continuous signal Pattern<Double>.
    public func pan(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("pan"))
    }

    public func s(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["s": .string($0)] })
    }

    public func note(_ pattern: String) -> ControlPattern {
        withControl(notePattern(pattern))
    }

    // MARK: - Delay controls

    public func delay(_ value: Double) -> ControlPattern {
        withControl(.pure(["delay": .double(value)]))
    }

    public func delay(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["delay": .double(Double($0) ?? 0.0)] })
    }

    public func delaytime(_ value: Double) -> ControlPattern {
        withControl(.pure(["delaytime": .double(value)]))
    }

    public func delaytime(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["delaytime": .double(Double($0) ?? 0.25)] })
    }

    public func delayfeedback(_ value: Double) -> ControlPattern {
        withControl(.pure(["delayfeedback": .double(value)]))
    }

    public func delayfeedback(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["delayfeedback": .double(Double($0) ?? 0.5)] })
    }

    // MARK: - Fase 3: Synth ADSR + filter + speed

    public func attack(_ value: Double) -> ControlPattern {
        withControl(.pure(["attack": .double(value)]))
    }

    public func attack(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["attack": .double(Double($0) ?? 0.001)] })
    }

    public func decay(_ value: Double) -> ControlPattern {
        withControl(.pure(["decay": .double(value)]))
    }

    public func decay(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["decay": .double(Double($0) ?? 0.05)] })
    }

    public func sustain(_ value: Double) -> ControlPattern {
        withControl(.pure(["sustain": .double(value)]))
    }

    public func sustain(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["sustain": .double(Double($0) ?? 0.6)] })
    }

    public func release(_ value: Double) -> ControlPattern {
        withControl(.pure(["release": .double(value)]))
    }

    public func release(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["release": .double(Double($0) ?? 0.01)] })
    }

    /// lpf — low-pass filter frequency (Hz). Alias of cutoff for synths.
    public func lpf(_ value: Double) -> ControlPattern {
        withControl(.pure(["lpf": .double(value)]))
    }

    public func lpf(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["lpf": .double(Double($0) ?? 20000.0)] })
    }

    /// Modulate lpf with a continuous signal Pattern<Double>.
    /// Example: .lpf(sine.range(200, 2000)) → smooth filter sweep.
    /// Per-event value: evaluated at event whole.begin (see COMPATIBILITY.md).
    /// Intra-event smoothing (per-sample interpolation) arrives with P0-3.
    public func lpf(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("lpf"))
    }

    /// hpf — high-pass filter frequency (Hz).
    public func hpf(_ value: Double) -> ControlPattern {
        withControl(.pure(["hpf": .double(value)]))
    }

    public func hpf(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["hpf": .double(Double($0) ?? 0.0)] })
    }

    /// Modulate hpf with a continuous signal Pattern<Double>.
    public func hpf(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("hpf"))
    }

    /// resonance — filter Q (0..50 per Strudel public docs). Applied to lpf/hpf.
    public func resonance(_ value: Double) -> ControlPattern {
        withControl(.pure(["resonance": .double(value)]))
    }

    public func resonance(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["resonance": .double(Double($0) ?? 0.0)] })
    }

    /// Modulate resonance with a continuous signal Pattern<Double>.
    public func resonance(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("resonance"))
    }

    /// speed — sample playback rate (1=normal, 2=double speed, 0.5=half).
    /// Negative: reverse not supported (documented). Multiplied with note repitch.
    public func speed(_ value: Double) -> ControlPattern {
        withControl(.pure(["speed": .double(value)]))
    }

    public func speed(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["speed": .double(Double($0) ?? 1.0)] })
    }

    /// Modulate speed with a continuous signal Pattern<Double>.
    public func speed(_ signal: Pattern<Double>) -> ControlPattern {
        withControl(signal.asControl("speed"))
    }

    // MARK: - Fase 4: Distortion / Saturation

    /// shape(x) — soft saturation, x 0..1.
    /// Implemented via AVAudioUnitDistortion (per-chain). x → wetDryMix (x×100).
    public func shape(_ value: Double) -> ControlPattern {
        withControl(.pure(["shape": .double(value)]))
    }

    public func shape(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["shape": .double(Double($0) ?? 0.0)] })
    }

    /// distort(x) — distortion, x 0..1.
    /// Same DSP path as shape() but mapped through a different preset (SpeechWaves).
    /// Documented approximation: Strudel uses distinct distortion curves; here we
    /// use AVAudioUnitDistortion with different wetDryMix treatment.
    public func distort(_ value: Double) -> ControlPattern {
        withControl(.pure(["distort": .double(value)]))
    }

    public func distort(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["distort": .double(Double($0) ?? 0.0)] })
    }

    // MARK: - Fase 4: Bitcrusher

    /// crush(n) — bitcrusher. n = effective bit depth (typical range 4..16).
    /// Lower n = more lo-fi. DSP: quantisation round(s × 2^(n-1)) / 2^(n-1).
    /// For samples: applied as buffer pre-processing before scheduling.
    /// For synths: applied inside the render block.
    public func crush(_ value: Double) -> ControlPattern {
        withControl(.pure(["crush": .double(value)]))
    }

    public func crush(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["crush": .double(Double($0) ?? 16.0)] })
    }

    // MARK: - Fase 4: Vowel formant filter

    /// vowel("a"|"e"|"i"|"o"|"u") — formant filter.
    /// Implemented via AVAudioUnitEQ with 3 bandpass bands at standard F1/F2/F3.
    /// Patroneable: vowel("<a o>") alternates per cycle.
    /// Single-char vowel strings (a, e, i, o, u) are passed as pure values;
    /// longer strings or strings with spaces/brackets are treated as mini-notation.
    public func vowel(_ str: String) -> ControlPattern {
        let vowels: Set<String> = ["a", "e", "i", "o", "u"]
        if vowels.contains(str.lowercased()) {
            // Direct vowel value
            return withControl(.pure(["vowel": .string(str.lowercased())]))
        }
        // Mini-notation pattern (e.g. "<a o>", "a e i")
        return withControl(parseMini(str).map { ["vowel": .string($0.lowercased())] })
    }

    // MARK: - ADSR short aliases (Strudel public API)

    /// dec(x) — alias for decay(x). Strudel short alias.
    public func dec(_ value: Double) -> ControlPattern { decay(value) }
    public func dec(_ pattern: String) -> ControlPattern { decay(pattern) }

    /// att(x) — alias for attack(x). Strudel short alias.
    public func att(_ value: Double) -> ControlPattern { attack(value) }
    public func att(_ pattern: String) -> ControlPattern { attack(pattern) }

    /// sus(x) — alias for sustain(x). Strudel short alias.
    public func sus(_ value: Double) -> ControlPattern { sustain(value) }
    public func sus(_ pattern: String) -> ControlPattern { sustain(pattern) }

    /// rel(x) — alias for release(x). Strudel short alias.
    public func rel(_ value: Double) -> ControlPattern { release(value) }
    public func rel(_ pattern: String) -> ControlPattern { release(pattern) }

    // MARK: - Bank selection

    /// bank("name") — sets a sample bank prefix.
    /// In the scheduler, the effective sample key becomes "\(bank)_\(s)".
    /// Semantics match Strudel: s("bd").bank("tr909") → looks up "tr909_bd".
    /// Patroneable: bank("<tr909 tr808>") alternates per cycle.
    public func bank(_ name: String) -> ControlPattern {
        // Single bare bank name (no spaces or brackets → pure value)
        if !name.contains(" ") && !name.contains("<") && !name.contains("[") {
            return withControl(.pure(["bank": .string(name)]))
        }
        // Mini-notation pattern
        return withControl(parseMini(name).map { ["bank": .string($0)] })
    }

    // MARK: - P0-4: orbit

    /// orbit(n) — route this layer/pattern to an independent orbit bus.
    /// Each orbit has its own reverb (room+size) and delay chain feeding mainMixer.
    /// Layers on the same orbit share the same reverb/delay tail (as in Strudel/SuperDirt).
    ///
    /// Default: orbit 1 (Strudel public docs: "By default all patterns use orbit 1").
    /// Verified: strudel.cc/learn/effects states the orbit default is 1, and patterns
    /// without an explicit .orbit() share orbit 1.
    ///
    /// Patroneable: .orbit("<1 2>") alternates orbits per cycle.
    public func orbit(_ value: Double) -> ControlPattern {
        withControl(.pure(["orbit": .double(value)]))
    }

    public func orbit(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["orbit": .double(Double($0) ?? 1.0)] })
    }

    // MARK: - P1-5: duck / duckattack / duckdepth (sidechain)

    /// duck(n) — events on this pattern attenuate the gain of orbit bus n.
    /// At each event onset: orbit n's gain drops to (1 - duckdepth) immediately,
    /// then recovers linearly over duckattack seconds.
    ///
    /// Semantics (Strudel public docs / superdough):
    ///   duck(n): target orbit index to attenuate.
    ///   duckattack: recovery time in seconds (default: 0.1s — recovery from duck to full).
    ///     Note: in Strudel, "duckattack" refers to the recovery (not the onset drop),
    ///     per the superdough source comments. We follow this convention.
    ///   duckdepth: attenuation depth 0..1. 0 = no ducking, 1 = full silence (default: 1).
    ///
    /// Implementation: on event dispatch with duck(n), the scheduler schedules a gain ramp
    /// on OrbitBus[n].gain: immediately drops to (1-duckdepth) at absoluteTime,
    /// then recovers to 1.0 over duckattack seconds using poolQueue step interpolation
    /// at 10ms resolution (100 steps/second). Documented: 10ms step resolution.
    public func duck(_ value: Double) -> ControlPattern {
        withControl(.pure(["duck": .double(value)]))
    }

    public func duck(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["duck": .double(Double($0) ?? 0.0)] })
    }

    /// duckattack(s) — recovery time after ducking (seconds). Default: 0.1.
    public func duckattack(_ value: Double) -> ControlPattern {
        withControl(.pure(["duckattack": .double(value)]))
    }

    public func duckattack(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["duckattack": .double(Double($0) ?? 0.1)] })
    }

    /// duckdepth(x) — ducking depth 0..1. 0=no duck, 1=full silence. Default: 1.
    public func duckdepth(_ value: Double) -> ControlPattern {
        withControl(.pure(["duckdepth": .double(value)]))
    }

    public func duckdepth(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["duckdepth": .double(Double($0) ?? 1.0)] })
    }

    // MARK: - P1-6: lpenv / hpenv (filter envelope)

    /// lpenv(octaves) — modulate lpf cutoff with the voice ADSR envelope.
    ///
    /// Effective cutoff at time t: lpf_effective(t) = lpf_base × 2^(lpenv × env(t))
    /// where env(t) is the ADSR envelope value at sample t (0..1 during attack/decay/sustain,
    /// 0..sustain during release).
    ///
    /// Semantics (superdough public docs / strudel.cc/learn/effects):
    ///   lpenv in octaves. Positive: cutoff opens upward (brighter) with envelope.
    ///   Negative: cutoff moves downward (darker) with envelope.
    ///   0 = no modulation.
    ///
    /// Formula confirmed: lpf_effective = lpf_base * 2^(lpenv * env).
    ///   At env=1.0 (peak attack): lpf * 2^lpenv (lpenv=2 → 4× the base cutoff).
    ///   At env=0.0 (silence): lpf * 2^0 = lpf (base cutoff).
    ///
    /// Synths: coefs recomputed every 64 samples using the current envelope value.
    ///   This matches the biquad ramp already in SynthVoice; lpenv adds envelope tracking.
    /// Samples: not applied (sample buffer preprocessing has no ADSR curve access).
    ///   Documented: lpenv is synth-only in MiniEngine (same as Strudel behaviour).
    ///
    /// Default: 0 (no modulation).
    public func lpenv(_ value: Double) -> ControlPattern {
        withControl(.pure(["lpenv": .double(value)]))
    }

    public func lpenv(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["lpenv": .double(Double($0) ?? 0.0)] })
    }

    /// hpenv(octaves) — same semantics as lpenv but for hpf.
    ///   hpf_effective(t) = hpf_base × 2^(hpenv × env(t))
    public func hpenv(_ value: Double) -> ControlPattern {
        withControl(.pure(["hpenv": .double(value)]))
    }

    public func hpenv(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["hpenv": .double(Double($0) ?? 0.0)] })
    }

    /// lpq(q) — Q of the low-pass filter.
    /// Alias of resonance() for the lpf specifically.
    /// Strudel public docs: lpq and resonance are aliases for lpf Q.
    /// Verified: strudel.cc/learn/effects shows lpq as the Q parameter for lpf.
    /// Implementation: stores as "resonance" control field (same effect as resonance()).
    public func lpq(_ value: Double) -> ControlPattern {
        resonance(value)
    }

    public func lpq(_ pattern: String) -> ControlPattern {
        resonance(pattern)
    }

    /// hpq(q) — Q of the high-pass filter.
    /// Alias of resonance() for hpf. Same implementation (single resonance Q shared).
    /// Strudel docs: hpq exists as a symmetric alias to lpq for hpf.
    public func hpq(_ value: Double) -> ControlPattern {
        resonance(value)
    }

    public func hpq(_ pattern: String) -> ControlPattern {
        resonance(pattern)
    }

    // MARK: - P1-7: add() — arithmetic pattern combination

    /// add(other: ControlPattern) — structural addition of numeric control fields.
    ///
    /// Semantics (Strudel / Tidal public docs):
    ///   appLeft ("add"): structure from BASE pattern; values from OTHER are added
    ///   field-by-field when the field exists in both patterns and both values are numeric.
    ///   Non-numeric fields (strings) are NOT added; the base wins.
    ///
    ///   Key use cases:
    ///     .add(note("12"))     → transpose: adds 12 to "note" field (one octave up)
    ///     .add(note("[0,.12]"))→ detune: two simultaneous events (+0, +0.12 MIDI semitones)
    ///     .add(n("7"))         → shift scale degree before .scale() resolves
    ///
    ///   Structure: structure comes from BASE (appLeft).
    ///   When other has multiple haps (e.g. note("[0,.12]") = chord = 2 haps), each base
    ///   hap is duplicated to combine with each other hap — resulting in base.count × other.count
    ///   output haps. This is the "app" in applicative: base × other cartesian product,
    ///   filtered by overlap. (Verified against oracle: see P1-7 tests.)
    ///
    /// Implementation: for each base hap, query other over base's whole span.
    ///   For each (base_hap, other_hap) with overlapping wholes:
    ///     new_whole = base_hap.whole (structure from base)
    ///     new_part  = intersection(base_hap.part, other_hap.whole)
    ///     new_value = base_value with numeric fields incremented by other_value amounts
    public func add(_ other: ControlPattern) -> ControlPattern {
        Pattern { span in
            let baseHaps = self.query(span)
            var result: [Hap<[String: ControlValue]>] = []

            for baseHap in baseHaps {
                let querySpan = baseHap.whole ?? baseHap.part
                let otherHaps = other.query(querySpan)

                for otherHap in otherHaps {
                    let otherExtent = otherHap.whole ?? otherHap.part
                    guard let newPart = baseHap.part.intersection(otherExtent) else { continue }
                    // Merge: add numeric fields, keep string fields from base
                    var merged = baseHap.value
                    for (key, otherVal) in otherHap.value {
                        if let baseVal = merged[key],
                           let bd = baseVal.doubleValue,
                           let od = otherVal.doubleValue {
                            merged[key] = .double(bd + od)
                        }
                        // If base has no such field, add it from other (additive default)
                        else if merged[key] == nil, let od = otherVal.doubleValue {
                            merged[key] = .double(od)
                        }
                        // String fields from other: skip (base string wins — e.g. "s")
                    }
                    result.append(Hap(whole: baseHap.whole, part: newPart, value: merged))
                }
            }
            return result
        }
    }

    // MARK: - P1-8: postgain, size, fb/dt aliases

    /// postgain(x) — post-effects gain multiplier.
    ///
    /// Semantics: multiplier applied after the effect chain.
    ///   Synths: multiplied after filter/crush in SynthVoice render (implemented as a
    ///     second gain factor applied to each sample output, before accumulation).
    ///   Samples: multiplied into player.volume at dispatch time. Because samples are
    ///     preprocessed (lpf/crush applied as buffer copy), postgain is applied after
    ///     those but before the orbit bus (same signal point as gain in practice — no
    ///     distortion-after-postgain distinction is possible without a per-voice AU chain).
    ///     Documented compromise: for samples, gain and postgain are equivalent except
    ///     they stack multiplicatively (both are applied).
    public func postgain(_ value: Double) -> ControlPattern {
        withControl(.pure(["postgain": .double(value)]))
    }

    public func postgain(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["postgain": .double(Double($0) ?? 1.0)] })
    }

    /// size(x) — reverb room size 0..1.
    ///
    /// Alias: roomsize.
    ///
    /// Semantics: maps to AVAudioUnitReverb preset per orbit bus.
    ///   Strudel uses a continuous size parameter; AVAudioUnitReverb has discrete presets.
    ///   Mapping (documented approximation):
    ///     size < 0.3  → .smallRoom
    ///     size < 0.6  → .mediumHall (default)
    ///     size < 0.8  → .largeHall
    ///     size >= 0.8 → .cathedral
    ///   Documented: this is an approximation. Strudel's reverb uses a continuous
    ///   algorithmic reverb (Freeverb-style); AVAudioUnitReverb uses impulse responses.
    ///   The preset mapping gives a perceptually similar "bigger room" progression.
    ///   Updated per event on the orbit bus (last event per orbit wins, same as room).
    public func size(_ value: Double) -> ControlPattern {
        withControl(.pure(["size": .double(value)]))
    }

    public func size(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["size": .double(Double($0) ?? 0.5)] })
    }

    /// roomsize(x) — alias for size(x).
    public func roomsize(_ value: Double) -> ControlPattern { size(value) }
    public func roomsize(_ pattern: String) -> ControlPattern { size(pattern) }

    /// fb(x) — alias for delayfeedback(x). Strudel short alias.
    public func fb(_ value: Double) -> ControlPattern { delayfeedback(value) }
    public func fb(_ pattern: String) -> ControlPattern { delayfeedback(pattern) }

    /// dt(x) — alias for delaytime(x). Strudel short alias.
    public func dt(_ value: Double) -> ControlPattern { delaytime(value) }
    public func dt(_ pattern: String) -> ControlPattern { delaytime(pattern) }

    // MARK: - Fase 4: Granular — chop / striate

    /// chop(n) — cut each sample event into n sequential sub-events.
    /// Each sub-event plays 1/n of the sample (begin/end fields 0..1).
    /// The time slot of each event is divided into n equal sub-slots.
    /// Semantic: event with whole=[a,b) becomes n sub-events, sub k:
    ///   time=[a + k*(b-a)/n, a + (k+1)*(b-a)/n), begin=k/n, end=(k+1)/n
    public func chop(_ n: Int) -> ControlPattern {
        guard n > 0 else { return self }
        let nd = Double(n)
        return Pattern { span in
            self.query(span).flatMap { hap -> [Hap<[String: ControlValue]>] in
                let whole = hap.whole ?? hap.part
                let dur   = whole.end - whole.begin
                let step  = dur / Rational(n)
                return (0..<n).compactMap { k -> Hap<[String: ControlValue]>? in
                    let subBegin  = whole.begin + step * Rational(k)
                    let subEnd    = whole.begin + step * Rational(k + 1)
                    let subWhole  = TimeSpan(subBegin, subEnd)
                    guard let newPart = subWhole.intersection(hap.part) else { return nil }
                    let fBegin = Double(k) / nd
                    let fEnd   = Double(k + 1) / nd
                    var newValue = hap.value
                    newValue["begin"] = .double(fBegin)
                    newValue["end"]   = .double(fEnd)
                    return Hap(whole: subWhole, part: newPart, value: newValue)
                }
            }
        }
    }

    /// striate(n) — granular interleaving.
    /// Assigns chunk `i mod n` to event `i` in the cycle.
    /// For a single-event pattern, striate(n) is equivalent to chop(n).
    /// For a multi-event pattern (e.g. s("pad bell")), striate(n) keeps the
    /// same event count but sets begin/end so each event plays a different chunk.
    /// This is a pattern-level operation: no extra sub-events are created.
    /// Semantic confirmed against oracle: event at index i → begin=i%n/n, end=(i%n+1)/n.
    public func striate(_ n: Int) -> ControlPattern {
        guard n > 0 else { return self }
        let nd = Double(n)
        return Pattern { span in
            // Collect all haps, then assign chunk index based on position in cycle
            let haps = self.query(span)
            // Sort by onset to assign stable indices
            let sorted = haps.sorted { $0.part.begin < $1.part.begin }
            return sorted.enumerated().map { (i, hap) in
                let chunk  = i % n
                let fBegin = Double(chunk) / nd
                let fEnd   = Double(chunk + 1) / nd
                var newValue = hap.value
                newValue["begin"] = .double(fBegin)
                newValue["end"]   = .double(fEnd)
                return Hap(whole: hap.whole, part: hap.part, value: newValue)
            }
        }
    }

    // MARK: - P3: Expresión y timing

    /// late(t) — desplaza el patrón hacia DESPUÉS en el tiempo (rotR).
    /// t en ciclos (0.25 = un cuarto de ciclo más tarde).
    /// Semántica Strudel public: late(t) mueve los eventos t ciclos hacia el futuro.
    public func late(_ t: Double) -> ControlPattern {
        rotR(Rational(approximating: t))
    }

    /// early(t) — desplaza el patrón hacia ANTES en el tiempo (rotL).
    /// t en ciclos (0.25 = un cuarto de ciclo antes).
    /// Semántica Strudel public: early(t) mueve los eventos t ciclos hacia el pasado.
    public func early(_ t: Double) -> ControlPattern {
        rotL(Rational(approximating: t))
    }

    /// transpose(semitones) — transpone el campo "note" en semitones.
    /// Si el hap no tiene campo "note" (numérico) lo deja sin cambios.
    /// Semántica Strudel public: transpose(12) sube una octava.
    public func transpose(_ semitones: Double) -> ControlPattern {
        map { dict in
            var out = dict
            if let noteVal = dict["note"]?.doubleValue {
                out["note"] = .double(noteVal + semitones)
            }
            return out
        }
    }

    /// Overload Int para comodidad: transpose(12).
    public func transpose(_ semitones: Int) -> ControlPattern {
        transpose(Double(semitones))
    }

    /// velocity(v) — establece el campo "velocity" (0..1).
    /// Se multiplica con gain en el scheduler para el gain efectivo.
    /// v=1.0 (default) = sin cambio; v=0.5 = mitad de volumen.
    public func velocity(_ v: Double) -> ControlPattern {
        withControl(.pure(["velocity": .double(v)]))
    }

    /// velocity(mini) — velocity desde mini-notación.
    public func velocity(_ mini: String) -> ControlPattern {
        withControl(parseMini(mini).map { ["velocity": .double(Double($0) ?? 1.0)] })
    }

    /// clip(x) — recorta la duración del evento a x fracción del whole.
    /// clip<1 = staccato (x=0.5 → dura la mitad); clip>1 = legato (sustain alargado).
    /// Se aplica como multiplicador de durationSec en ScheduledEvent.
    public func clip(_ x: Double) -> ControlPattern {
        withControl(.pure(["clip": .double(x)]))
    }

    /// clip(mini) — clip desde mini-notación.
    public func clip(_ mini: String) -> ControlPattern {
        withControl(parseMini(mini).map { ["clip": .double(Double($0) ?? 1.0)] })
    }

    // MARK: - Scale / n

    public func n(_ pattern: String) -> ControlPattern {
        withControl(nPattern(pattern))
    }

    public func scale(_ value: String) -> ControlPattern {
        withControl(.pure(["scale": .string(value)])).resolveScale()
    }

    /// Resolve any hap that has both "n" and "scale" fields into a "note" (MIDI).
    /// After resolution, "n" and "scale" fields are removed and replaced with "note".
    public func resolveScale() -> ControlPattern {
        Pattern { span in
            self.query(span).map { hap in
                guard let scaleStr = hap.value["scale"]?.stringValue,
                      let nVal = hap.value["n"]?.doubleValue,
                      let (root, intervals) = parseScale(scaleStr) else {
                    return hap
                }
                let idx = Int(nVal.rounded())
                let midi = scaleDegreeToMidi(index: idx, root: root, intervals: intervals)
                var newValue = hap.value
                newValue["note"] = .double(Double(midi))
                newValue.removeValue(forKey: "n")
                newValue.removeValue(forKey: "scale")
                return Hap(whole: hap.whole, part: hap.part, value: newValue)
            }
        }
    }
}

// MARK: - Synth name registry

/// Names recognised as built-in oscillator synths (not sample look-ups).
/// Verified against Strudel public docs: s("sawtooth"), s("square"), s("sine"), s("triangle")
/// all produce oscillator-based tones.
public let synthNames: Set<String> = ["sawtooth", "square", "sine", "triangle"]

/// Returns true when `name` refers to a built-in oscillator synth.
public func isSynthName(_ name: String) -> Bool {
    synthNames.contains(name.lowercased())
}

// MARK: - Top-level constructors

/// s("pad bell") → ControlPattern with field "s"
/// When the name is a synth (sawtooth, square, sine, triangle) it also sets
/// the "synth" field to the same string so the scheduler can distinguish
/// synth layers from sample layers.
///
/// Supports :n variation syntax: "tabla:3" → s="tabla", n=3 (Strudel convention).
/// Without :n → n defaults to 0. With .n("...") chained, the chain value wins.
/// Behaviour matches Strudel: s("tabla:3") sets n=3 in the hap, and the
/// scheduler selects variation index (n % arrayLength) from the bank.
public func s(_ miniNotation: String) -> ControlPattern {
    parseMini(miniNotation).map { token -> [String: ControlValue] in
        // Parse "name:index" variation syntax
        let (sName, nIdx) = parseColonN(token)
        var map: [String: ControlValue] = ["s": .string(sName)]
        if let idx = nIdx {
            map["n"] = .double(Double(idx))
        }
        if isSynthName(sName) { map["synth"] = .string(sName) }
        return map
    }
}

/// Parse "name:n" token into (name, optional index).
/// "tabla:3" → ("tabla", 3); "bd" → ("bd", nil); "bd:0" → ("bd", 0).
func parseColonN(_ token: String) -> (String, Int?) {
    // Find last ':' to allow names like "tr909:1"
    guard let colonIdx = token.lastIndex(of: ":") else { return (token, nil) }
    let name = String(token[..<colonIdx])
    let rest = String(token[token.index(after: colonIdx)...])
    if name.isEmpty { return (token, nil) }
    if let idx = Int(rest) { return (name, idx) }
    // rest is not a number — treat whole token as name (e.g. "http://..." edge case)
    return (token, nil)
}

/// sound("sawtooth") — alias of s() in Strudel.
/// Produces the same control map. The scheduler recognises "synth" field.
public func sound(_ miniNotation: String) -> ControlPattern {
    s(miniNotation)
}

/// note("c4 e4 g4") → ControlPattern with field "note" (MIDI number as double)
public func note(_ miniNotation: String) -> ControlPattern {
    notePattern(miniNotation)
}

// MARK: - Helpers

/// Parse a mini-notation string as Pattern<String>.
func parseMini(_ notation: String) -> Pattern<String> {
    MiniNotationCore.parse(notation)
}

/// Parse a note mini-notation and convert note names to MIDI doubles.
func notePattern(_ notation: String) -> ControlPattern {
    parseMini(notation).map { token -> [String: ControlValue] in
        if let midi = midiNote(for: token) {
            return ["note": .double(Double(midi))]
        } else if let n = Double(token) {
            return ["note": .double(n)]
        }
        // Unknown: pass as string (will be ignored by scheduler)
        return ["note": .string(token)]
    }
}

// MARK: - stack overload for ControlPattern

/// Top-level pan constructor
public func pan(_ miniNotation: String) -> ControlPattern {
    parseMini(miniNotation).map { ["pan": .double(Double($0) ?? 0.5)] }
}

// MARK: - n() helper

/// Parse n mini-notation and produce {"n": double} control map.
func nPattern(_ notation: String) -> ControlPattern {
    parseMini(notation).map { token -> [String: ControlValue] in
        if let v = Double(token) {
            return ["n": .double(v)]
        }
        return ["n": .string(token)]
    }
}

/// Top-level n constructor
public func n(_ miniNotation: String) -> ControlPattern {
    nPattern(miniNotation)
}

// MARK: - scale() helper — resolves n+scale to MIDI note

/// Scale definitions: maps scale name → intervals from root (semitones, repeating per octave).
/// Documented: these are the intervals for one octave; index wraps with octave shifts.
private let scaleIntervals: [String: [Int]] = [
    "major":       [0, 2, 4, 5, 7, 9, 11],
    "minor":       [0, 2, 3, 5, 7, 8, 10],   // natural minor
    "dorian":      [0, 2, 3, 5, 7, 9, 10],
    "mixolydian":  [0, 2, 4, 5, 7, 9, 10],
    "pentatonic":  [0, 2, 4, 7, 9],
]

/// Root note names → MIDI number for octave 3 (Strudel default: C3 = MIDI 48).
/// Verified against oracle: n(0).scale("C:minor") → MIDI 48.
private let rootMidi: [String: Int] = [
    "C": 48, "C#": 49, "Db": 49,
    "D": 50, "D#": 51, "Eb": 51,
    "E": 52,
    "F": 53, "F#": 54, "Gb": 54,
    "G": 55, "G#": 56, "Ab": 56,
    "A": 57, "A#": 58, "Bb": 58,
    "B": 59,
]

/// Parse "Root:scalename" → (rootMidi, intervals).
public func parseScale(_ scaleStr: String) -> (Int, [Int])? {
    let parts = scaleStr.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let rootStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
    let scaleName = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
    guard let root = rootMidi[rootStr],
          let intervals = scaleIntervals[scaleName] else { return nil }
    return (root, intervals)
}

/// Convert scale degree index → MIDI note.
/// Negative indices and indices beyond the octave wrap correctly.
public func scaleDegreeToMidi(index: Int, root: Int, intervals: [Int]) -> Int {
    let stepsPerOctave = intervals.count
    // Wrap index to [0, stepsPerOctave) and compute octave shift
    let octaveShift = index >= 0
        ? index / stepsPerOctave
        : (index - stepsPerOctave + 1) / stepsPerOctave
    let wrappedIdx = ((index % stepsPerOctave) + stepsPerOctave) % stepsPerOctave
    return root + 12 * octaveShift + intervals[wrappedIdx]
}

/// stack for ControlPatterns — calls the generic Pattern stack.
/// We cast to the base type first to avoid ambiguous dispatch to this overload.
public func stackCP(_ patterns: [ControlPattern]) -> ControlPattern {
    // Use the generic stack via the pattern's query — avoids circular overload resolution.
    Pattern { span in
        patterns.flatMap { $0.query(span) }
    }
}

public func stackCP(_ patterns: ControlPattern...) -> ControlPattern {
    stackCP(patterns)
}
