#!/usr/bin/env python3
"""
generate_samples.py — Generate WAV samples for DemoStrudel (F0).
Uses only Python 3 stdlib: wave, struct, math.  No numpy required.

Outputs:
  Sources/DemoStrudelApp/Samples/pad.wav   — warm drone ~8 s, loop-friendly
  Sources/DemoStrudelApp/Samples/bell.wav  — tibetan-bell tone, tuned to C4 (261.63 Hz)

Audio specs: 44100 Hz, 16-bit, stereo.

IMPORTANT — bell.wav is tuned to C4 (261.63 Hz) as the fundamental.
The NativeEngine will repitch from C4 to any target note using:
    playbackRate = 2^((targetMIDI - 60) / 12)
"""

import math
import struct
import wave
import os

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SAMPLE_RATE = 44100
BITS        = 16
CHANNELS    = 2
MAX_AMP     = 32767  # int16 peak

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Sources", "DemoStrudelApp", "Samples"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def clamp16(x: float) -> int:
    return max(-MAX_AMP, min(MAX_AMP, int(x)))


def write_wav(path: str, frames: list[tuple[int, int]]) -> None:
    """Write a list of (left, right) int16 sample pairs to a WAV file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(BITS // 8)
        wf.setframerate(SAMPLE_RATE)
        packed = bytearray()
        for left, right in frames:
            packed += struct.pack("<hh", left, right)
        wf.writeframes(bytes(packed))
    duration = len(frames) / SAMPLE_RATE
    size_kb = os.path.getsize(path) / 1024
    print(f"  Written: {path}")
    print(f"    Duration : {duration:.3f} s")
    print(f"    Size     : {size_kb:.1f} KB")


# ---------------------------------------------------------------------------
# pad.wav — warm drone C3+G3+C4 with detuning, fade-in/fade-out crossfade
# ---------------------------------------------------------------------------
# Duration: 8 s total.  The tone is fade-in for 1 s, sustain for 6 s, and
# fade-out for 1 s, so it loops cleanly (end amplitude == start amplitude == 0).

def generate_pad(path: str) -> None:
    print("\n[pad.wav] Generating warm drone (C3+G3+C4, loop-friendly, 8 s)...")

    duration   = 8.0
    n_samples  = int(SAMPLE_RATE * duration)
    fade_in    = int(SAMPLE_RATE * 1.0)   # 1 s fade-in
    fade_out   = int(SAMPLE_RATE * 1.0)   # 1 s fade-out

    # Chord partials: (frequency_hz, amplitude_fraction, detune_cents)
    # C3 = 130.81 Hz, G3 = 196.00 Hz, C4 = 261.63 Hz
    partials = [
        # --- C3 root (fundamental + overtones, slightly detuned for warmth)
        (130.81,  0.45,   0.0),
        (130.81 * 2, 0.18,  +3.0),   # octave up, slight detune
        (130.81 * 3, 0.08,  -2.0),   # 5th harmonic
        # --- G3 fifth
        (196.00,  0.35,  +2.0),
        (196.00 * 2, 0.12, -3.0),
        # --- C4 octave
        (261.63,  0.25,   0.0),
        (261.63 * 1.5, 0.07, +4.0),  # G4 subtle
    ]

    def detune(freq: float, cents: float) -> float:
        return freq * (2 ** (cents / 1200.0))

    frames: list[tuple[int, int]] = []
    for i in range(n_samples):
        t = i / SAMPLE_RATE

        # Envelope: linear fade-in, sustain, linear fade-out
        if i < fade_in:
            env = i / fade_in
        elif i >= n_samples - fade_out:
            env = (n_samples - i) / fade_out
        else:
            env = 1.0

        # Slow LFO for gentle movement (0.05 Hz modulates overall amplitude ±3%)
        lfo = 1.0 + 0.03 * math.sin(2 * math.pi * 0.05 * t)

        # Sum partials — slight stereo spread via tiny phase offset per partial
        left_sample  = 0.0
        right_sample = 0.0
        for idx, (freq, amp, dcents) in enumerate(partials):
            f = detune(freq, dcents)
            phase_offset = (idx % 3) * 0.04   # 0, 0.04, or 0.08 rad spread
            wave_l = amp * math.sin(2 * math.pi * f * t)
            wave_r = amp * math.sin(2 * math.pi * f * t + phase_offset)
            left_sample  += wave_l
            right_sample += wave_r

        # Soft clip (tanh-like) then scale
        left_sample  = math.tanh(left_sample  * 0.8) * env * lfo * MAX_AMP * 0.55
        right_sample = math.tanh(right_sample * 0.8) * env * lfo * MAX_AMP * 0.55

        frames.append((clamp16(left_sample), clamp16(right_sample)))

    write_wav(path, frames)


# ---------------------------------------------------------------------------
# bell.wav — tibetan bell tuned to C4 (261.63 Hz), ~3 s, inharmonic partials
# ---------------------------------------------------------------------------
# IMPORTANT: fundamental = C4 = 261.63 Hz.
# The NativeEngine repitches this sample from C4 (MIDI 60) to any other note.
# Inharmonic partial ratios derived from typical tibetan singing-bowl physics.
# Each partial has its own exponential decay rate (higher partials decay faster).

def generate_bell(path: str) -> None:
    print("\n[bell.wav] Generating tibetan bell tone (C4 = 261.63 Hz, ~3 s)...")

    # C4 fundamental — THIS IS THE PITCH BASE used by NativeEngine for repitching
    C4_HZ = 261.63   # MIDI note 60

    duration  = 3.0
    n_samples = int(SAMPLE_RATE * duration)
    attack    = int(SAMPLE_RATE * 0.003)  # 3 ms attack (very sharp)

    # Inharmonic partials typical of a tibetan singing bowl.
    # Ratios relative to C4 fundamental, amplitude, and decay time constant (s).
    # Higher modes ring shorter.
    partials = [
        # (freq_ratio, amplitude, decay_tau_sec)
        (1.000,  0.60,  2.8),    # fundamental C4
        (2.756,  0.30,  1.6),    # first overtone (inharmonic ~2.76×)
        (5.404,  0.14,  0.9),    # second overtone (~5.4×)
        (8.933,  0.07,  0.5),    # third overtone
        (13.34,  0.04,  0.3),    # fourth overtone (very faint shimmer)
        # Sub-octave air (adds body)
        (0.501,  0.10,  1.2),
    ]

    frames: list[tuple[int, int]] = []
    for i in range(n_samples):
        t = i / SAMPLE_RATE

        # Per-partial amplitude envelope: sharp attack, exponential decay
        if i < attack:
            attack_env = i / attack
        else:
            attack_env = 1.0

        left_sample  = 0.0
        right_sample = 0.0

        for idx, (ratio, amp, tau) in enumerate(partials):
            freq  = C4_HZ * ratio
            decay = math.exp(-t / tau)
            # Tiny stereo width per partial (alternating L/R phase)
            phase_l = 0.0
            phase_r = (0.02 if idx % 2 == 0 else -0.02)
            wave_l = amp * decay * attack_env * math.sin(2 * math.pi * freq * t + phase_l)
            wave_r = amp * decay * attack_env * math.sin(2 * math.pi * freq * t + phase_r)
            left_sample  += wave_l
            right_sample += wave_r

        # Scale to int16
        left_sample  = clamp16(left_sample  * MAX_AMP * 0.70)
        right_sample = clamp16(right_sample * MAX_AMP * 0.70)

        frames.append((left_sample, right_sample))

    write_wav(path, frames)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    pad_path  = os.path.join(OUTPUT_DIR, "pad.wav")
    bell_path = os.path.join(OUTPUT_DIR, "bell.wav")

    generate_pad(pad_path)
    generate_bell(bell_path)

    print("\nDone. Samples ready in:", OUTPUT_DIR)
