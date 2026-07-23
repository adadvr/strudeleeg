#pragma once

// ---------------------------------------------------------------------------
// StrudelDSP — bloques DSP portados VERBATIM de MiniEngine/SynthVoice.swift
// para garantizar paridad de sonido con el backend AVAudioEngine:
//   • polyBLEP (osciladores band-limited)
//   • Biquad direct-form II transposed + coeficientes Audio EQ Cookbook (RBJ)
// Header-only, sin dependencias JUCE (solo <cmath>).
// ---------------------------------------------------------------------------

#include <cmath>
#include <algorithm>

namespace strudel {

// polyBLEP correction. t = fase normalizada (0..1), dt = incremento de fase/sample.
inline double polyBLEP (double t, double dt) noexcept
{
    if (t < dt)
    {
        const double x = t / dt;
        return x + x - x * x - 1.0;
    }
    else if (t > 1.0 - dt)
    {
        const double x = (t - 1.0) / dt;
        return x * x + x + x + 1.0;
    }
    return 0.0;
}

// Biquad direct-form II transposed (idéntico a BiquadFilter de SynthVoice.swift).
struct Biquad
{
    double nb0 { 1.0 }, nb1 { 0.0 }, nb2 { 0.0 };  // b/a0
    double na1 { 0.0 }, na2 { 0.0 };               // a/a0
    double z1  { 0.0 }, z2  { 0.0 };
    bool   bypass { true };

    inline double process (double x) noexcept
    {
        if (bypass) return x;
        const double y = nb0 * x + z1;
        z1 = nb1 * x - na1 * y + z2;
        z2 = nb2 * x - na2 * y;
        return y;
    }

    inline void resetState() noexcept { z1 = 0.0; z2 = 0.0; }
};

// Coeficientes lowpass Audio EQ Cookbook (RBJ). Escribe en b (bypass=false).
inline void setBiquadLPF (Biquad& b, double fc, double q, double fs) noexcept
{
    const double fcC = std::max (1.0, std::min (fc, fs * 0.4999));
    const double qC  = std::max (0.01, std::min (q, 50.0));
    const double w0    = 2.0 * M_PI * fcC / fs;
    const double alpha = std::sin (w0) / (2.0 * qC);
    const double cosW  = std::cos (w0);
    const double b0 = (1.0 - cosW) / 2.0;
    const double b1 =  1.0 - cosW;
    const double b2 = (1.0 - cosW) / 2.0;
    const double a0 =  1.0 + alpha;
    const double a1 = -2.0 * cosW;
    const double a2 =  1.0 - alpha;
    b.nb0 = b0 / a0; b.nb1 = b1 / a0; b.nb2 = b2 / a0;
    b.na1 = a1 / a0; b.na2 = a2 / a0;
    b.bypass = false;
}

// Coeficientes highpass Audio EQ Cookbook (RBJ).
inline void setBiquadHPF (Biquad& b, double fc, double q, double fs) noexcept
{
    const double fcC = std::max (1.0, std::min (fc, fs * 0.4999));
    const double qC  = std::max (0.01, std::min (q, 50.0));
    const double w0    = 2.0 * M_PI * fcC / fs;
    const double alpha = std::sin (w0) / (2.0 * qC);
    const double cosW  = std::cos (w0);
    const double b0 =  (1.0 + cosW) / 2.0;
    const double b1 = -(1.0 + cosW);
    const double b2 =  (1.0 + cosW) / 2.0;
    const double a0 =  1.0 + alpha;
    const double a1 = -2.0 * cosW;
    const double a2 =  1.0 - alpha;
    b.nb0 = b0 / a0; b.nb1 = b1 / a0; b.nb2 = b2 / a0;
    b.na1 = a1 / a0; b.na2 = a2 / a0;
    b.bypass = false;
}

} // namespace strudel
