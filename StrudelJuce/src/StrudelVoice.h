#pragma once

// ---------------------------------------------------------------------------
// StrudelVoice — una voz polifónica de oscilador, port fiel de SynthVoice.swift
// (MiniEngine) para paridad de sonido con AVAudioEngine:
//   oscilador polyBLEP (sine/sawtooth/square/triangle) + ADSR por muestra +
//   biquad LPF/HPF por voz con ramp de 64 muestras + lpenv/hpenv + bitcrush +
//   synthHeadroom 0.3 + arranque sample-accurate.
//
// Dominio de tiempo: índice de muestra ABSOLUTO del engine (en vez de host-time
// mach). trigger() fija startSample; render() calcula el frame de inicio dentro
// del bloque como (startSample - blockStartSample).
// ---------------------------------------------------------------------------

#include "StrudelDSP.h"
#include <string>

namespace strudel {

class StrudelVoice
{
public:
    enum class Wave { Sine, Sawtooth, Square, Triangle };

    StrudelVoice() = default;

    bool  isActive()   const noexcept { return active; }
    long long startSampleIndex() const noexcept { return startSample; }
    void setOrbit (int o) noexcept { orbitIdx = o; }
    int  orbit() const noexcept { return orbitIdx; }

    // Dispara la voz. Parámetros equivalentes a SynthVoice.trigger().
    // lpfHz/hpfHz <= 0 → filtro bypass. resonanceQ <= 0 → 0.707. pan 0..1 (0.5 = centro).
    void trigger (Wave wave,
                  double freq, double gain,
                  double attack, double decay, double sustain, double release,
                  double durationSec, double sampleRate,
                  long long startSampleAbs,
                  double lpfHz, double hpfHz, double resonanceQ,
                  double pan, double crushBits,
                  double lpenvOct, double hpenvOct, double postgain) noexcept;

    // Suma la salida de la voz en los buffers estéreo, desde el frame de inicio
    // relativo al bloque. blockStartSample = índice absoluto del frame 0 del bloque.
    // Devuelve false cuando la voz pasó a idle (el pool puede reclamarla).
    bool render (float* left, float* right,
                 long long blockStartSample, int numSamples, double sampleRate) noexcept;

    static Wave waveFromString (const std::string& s) noexcept;

private:
    enum class Stage { Attack, Decay, Sustain, Release, Idle };
    static constexpr int   envBlockSize = 64;
    static constexpr float synthHeadroom = 0.3f;

    bool   active { false };
    int    orbitIdx { 1 };
    Wave   waveform { Wave::Sine };
    double freq { 440.0 }, gain { 1.0 }, postgain { 1.0 };
    double phase { 0.0 }, dt { 0.0 };

    // ADSR
    int    atkSamp { 1 }, decSamp { 1 }, relSamp { 1 }, noteDurSamp { 1 };
    double susLvl { 0.8 };
    double envLevel { 0.0 };
    Stage  stage { Stage::Idle };
    long long samplesSinceOnset { 0 };
    long long startSample { 0 };

    // Triangle leaky-integrator
    double triInteg { 0.0 }, triDrive { 1.0 };

    // Bitcrush
    double crushBits { 0.0 };

    // Pan (constant power)
    double panL { 0.7071 }, panR { 0.7071 };

    // Biquad LPF/HPF con ramp
    Biquad lpf, hpf;
    double lpfCurrent { 20000.0 }, lpfTarget { 20000.0 };
    double hpfCurrent { 20.0 },    hpfTarget { 20.0 };
    double lpfQ { 0.707 }, hpfQ { 0.707 };
    int    lpfRampLeft { 0 }, hpfRampLeft { 0 };
    double filterSR { 44100.0 };

    // lpenv / hpenv
    double lpenvOctaves { 0.0 }, hpenvOctaves { 0.0 };
    double lpfBaseHz { 20000.0 }, hpfBaseHz { 20.0 };
    int    lpenvBlockLeft { 0 }, hpenvBlockLeft { 0 };
};

} // namespace strudel
