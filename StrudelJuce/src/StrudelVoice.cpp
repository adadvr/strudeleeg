#include "StrudelVoice.h"

namespace strudel {

StrudelVoice::Wave StrudelVoice::waveFromString (const std::string& s) noexcept
{
    if (s == "sawtooth") return Wave::Sawtooth;
    if (s == "square")   return Wave::Square;
    if (s == "triangle") return Wave::Triangle;
    return Wave::Sine;
}

void StrudelVoice::trigger (Wave wave,
                            double f, double g,
                            double attack, double decay, double sustain, double release,
                            double durationSec, double sampleRate,
                            long long startSampleAbs,
                            double lpfHz, double hpfHz, double resonanceQ,
                            double pan, double crush,
                            double lpenvOct, double hpenvOct, double postgainMult) noexcept
{
    freq     = f;
    gain     = g;
    postgain = std::max (0.0, postgainMult);
    waveform = wave;
    dt       = f / sampleRate;
    startSample = startSampleAbs;

    // Triangle drive frequency-compensado (idéntico a SynthVoice.swift).
    const double dtClamped = std::max (1e-6, f / sampleRate);
    const double L = 0.999;
    const double halfPeriodSamples = 0.5 / dtClamped;
    const double Lpow = std::pow (L, halfPeriodSamples);
    const double denom = std::max (1e-9, 1.0 - Lpow);
    triDrive = std::max (1e-6, std::min (2.0, (1.0 - L) * (1.0 + Lpow) / denom));

    atkSamp     = std::max (1, (int) (attack  * sampleRate));
    decSamp     = std::max (1, (int) (decay   * sampleRate));
    susLvl      = std::max (0.0, std::min (1.0, sustain));
    relSamp     = std::max (1, (int) (release * sampleRate));
    noteDurSamp = std::max (1, (int) (durationSec * sampleRate));

    phase = 0.0;
    envLevel = 0.0;
    triInteg = 0.0;
    samplesSinceOnset = 0;
    stage = Stage::Attack;
    active = true;
    crushBits = crush;

    // Pan constant-power: pan 0..1 → ángulo 0..π/2 (0.5 = centro, ambos 0.707).
    const double p = (pan < 0.0) ? 0.5 : std::max (0.0, std::min (1.0, pan));
    const double theta = p * (M_PI * 0.5);
    panL = std::cos (theta);
    panR = std::sin (theta);

    // Biquad LPF/HPF (Q default 0.707) con ramp de 64 desde el cutoff actual.
    filterSR = sampleRate;
    const double q = std::max (0.01, std::min (50.0, resonanceQ > 0.0 ? resonanceQ : 0.707));
    if (lpfHz > 0.0 && lpfHz < sampleRate * 0.4999)
    {
        lpfTarget = lpfHz; lpfQ = q; lpfRampLeft = 64;
        setBiquadLPF (lpf, lpfCurrent, q, sampleRate);
        lpf.resetState();
    }
    else { lpf.bypass = true; lpfCurrent = 20000.0; lpfTarget = 20000.0; lpfRampLeft = 0; }

    if (hpfHz > 1.0)
    {
        hpfTarget = hpfHz; hpfQ = q; hpfRampLeft = 64;
        setBiquadHPF (hpf, hpfCurrent, q, sampleRate);
        hpf.resetState();
    }
    else { hpf.bypass = true; hpfCurrent = 20.0; hpfTarget = 20.0; hpfRampLeft = 0; }

    lpenvOctaves = lpenvOct;
    hpenvOctaves = hpenvOct;
    lpfBaseHz = (lpfHz > 0.0) ? lpfHz : 20000.0;
    hpfBaseHz = (hpfHz > 0.0) ? hpfHz : 20.0;
    lpenvBlockLeft = 0;
    hpenvBlockLeft = 0;
}

bool StrudelVoice::render (float* left, float* right,
                           long long blockStartSample, int numSamples, double /*sampleRate*/) noexcept
{
    if (! active) return false;

    // Frame de inicio dentro del bloque (arranque sample-accurate).
    const long long offset = startSample - blockStartSample;
    if (offset >= (long long) numSamples) return true;   // aún pendiente
    int startFrame = (offset > 0) ? (int) offset : 0;

    for (int i = startFrame; i < numSamples; ++i)
    {
        // ── ADSR ──────────────────────────────────────────────────────────
        double env;
        switch (stage)
        {
            case Stage::Attack:
                envLevel += 1.0 / (double) atkSamp;
                if (envLevel >= 1.0) { envLevel = 1.0; stage = Stage::Decay; }
                env = envLevel;
                break;
            case Stage::Decay:
                envLevel -= (1.0 - susLvl) / (double) decSamp;
                if (envLevel <= susLvl) { envLevel = susLvl; stage = Stage::Sustain; }
                env = envLevel;
                break;
            case Stage::Sustain:
                env = susLvl;
                if (samplesSinceOnset >= noteDurSamp) stage = Stage::Release;
                break;
            case Stage::Release:
                envLevel -= susLvl / (double) relSamp;
                if (envLevel <= 0.0) { envLevel = 0.0; stage = Stage::Idle; active = false; }
                env = std::max (0.0, envLevel);
                break;
            case Stage::Idle:
            default:
                active = false;
                return false;
        }

        // ── Oscilador ─────────────────────────────────────────────────────
        double sample;
        switch (waveform)
        {
            case Wave::Sine:
                sample = std::sin (2.0 * M_PI * phase);
                break;
            case Wave::Sawtooth:
            {
                double s = 2.0 * phase - 1.0;
                s -= polyBLEP (phase, dt);
                sample = s;
                break;
            }
            case Wave::Square:
            {
                double s = phase < 0.5 ? 1.0 : -1.0;
                s += polyBLEP (phase, dt);
                s -= polyBLEP (std::fmod (phase + 0.5, 1.0), dt);
                sample = s;
                break;
            }
            case Wave::Triangle:
            {
                double sq = phase < 0.5 ? 1.0 : -1.0;
                sq += polyBLEP (phase, dt);
                sq -= polyBLEP (std::fmod (phase + 0.5, 1.0), dt);
                triInteg = triDrive * sq + triInteg * 0.999;
                sample = std::max (-1.0, std::min (1.0, triInteg));
                break;
            }
            default:
                sample = std::sin (2.0 * M_PI * phase);
                break;
        }

        // ── lpenv — LPF cutoff modulado por envolvente (cada 64 muestras) ──
        if (lpenvOctaves != 0.0 && ! lpf.bypass)
        {
            if (lpenvBlockLeft <= 0)
            {
                const double envMod = std::pow (2.0, lpenvOctaves * env);
                const double modCut = std::max (1.0, std::min (lpfBaseHz * envMod, filterSR * 0.4999));
                setBiquadLPF (lpf, modCut, lpfQ, filterSR);
                lpenvBlockLeft = envBlockSize;
            }
            --lpenvBlockLeft;
        }
        if (hpenvOctaves != 0.0 && ! hpf.bypass)
        {
            if (hpenvBlockLeft <= 0)
            {
                const double envMod = std::pow (2.0, hpenvOctaves * env);
                const double modCut = std::max (1.0, std::min (hpfBaseHz * envMod, filterSR * 0.4999));
                setBiquadHPF (hpf, modCut, hpfQ, filterSR);
                hpenvBlockLeft = envBlockSize;
            }
            --hpenvBlockLeft;
        }

        // ── Biquad LPF/HPF con ramp de cutoff ─────────────────────────────
        double filtered = sample;
        if (! lpf.bypass)
        {
            if (lpfRampLeft > 0)
            {
                const double step = (lpfTarget - lpfCurrent) / (double) (lpfRampLeft + 1);
                lpfCurrent += step; --lpfRampLeft;
                setBiquadLPF (lpf, lpfCurrent, lpfQ, filterSR);
            }
            filtered = lpf.process (filtered);
        }
        if (! hpf.bypass)
        {
            if (hpfRampLeft > 0)
            {
                const double step = (hpfTarget - hpfCurrent) / (double) (hpfRampLeft + 1);
                hpfCurrent += step; --hpfRampLeft;
                setBiquadHPF (hpf, hpfCurrent, hpfQ, filterSR);
            }
            filtered = hpf.process (filtered);
        }

        // ── env + gain + postgain + headroom ──────────────────────────────
        float out = (float) (filtered * env * gain * postgain) * synthHeadroom;

        // ── Bitcrush ──────────────────────────────────────────────────────
        if (crushBits > 0.0)
        {
            const float levels = (float) std::pow (2.0, crushBits - 1.0);
            out = std::round (out * levels) / levels;
        }

        // ── Pan constant-power + acumular ─────────────────────────────────
        left[i]  += out * (float) panL;
        right[i] += out * (float) panR;

        // ── Avanzar fase / contador ───────────────────────────────────────
        phase += dt;
        if (phase >= 1.0) phase -= 1.0;
        ++samplesSinceOnset;

        if (! active) break;   // release terminó dentro del bloque
    }

    return active;
}

} // namespace strudel
