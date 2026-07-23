#include "StrudelSample.h"
#include <cmath>

namespace strudel {

inline float StrudelSampleVoice::sampleAt (double p) const noexcept
{
    if (src == nullptr) return 0.0f;
    const long long i0 = (long long) p;
    if (i0 < 0 || i0 >= src->frames) return 0.0f;
    const long long i1 = (i0 + 1 < src->frames) ? i0 + 1 : i0;
    const float frac = (float) (p - (double) i0);

    // Promedio de canales (mono downmix) para escribir con pan constante.
    auto ch = [this] (const std::vector<float>& c, long long i) -> float {
        return (i < (long long) c.size()) ? c[(size_t) i] : 0.0f;
    };
    float a, b;
    if (src->channels >= 2)
    {
        a = 0.5f * (ch (src->ch0, i0) + ch (src->ch1, i0));
        b = 0.5f * (ch (src->ch0, i1) + ch (src->ch1, i1));
    }
    else
    {
        a = ch (src->ch0, i0);
        b = ch (src->ch0, i1);
    }
    return a + (b - a) * frac;
}

void StrudelSampleVoice::trigger (const SampleData* s,
                                  double r, double g, double pg,
                                  double beginFrac, double endFrac,
                                  double lpfHz, double hpfHz, double resonanceQ,
                                  double pan, double crush,
                                  bool hasADSR, double attack, double decay, double sustain,
                                  double release, double durationSec,
                                  double engineSampleRate,
                                  long long startSampleAbs) noexcept
{
    src  = s;
    rate = r;
    gain = g;
    postgain = std::max (0.0, pg);
    crushBits = crush;
    startSample = startSampleAbs;

    const double totalFrames = (s != nullptr) ? (double) s->frames : 0.0;
    const double bf = (beginFrac > 0.0) ? std::min (std::max (beginFrac, 0.0), 1.0) : 0.0;
    const double ef = (endFrac   > 0.0) ? std::min (std::max (endFrac,   0.0), 1.0) : 1.0;
    pos = bf * totalFrames;
    endFrame = std::max (pos + 1.0, ef * totalFrames);

    const double p = (pan < 0.0) ? 0.5 : std::max (0.0, std::min (1.0, pan));
    const double theta = p * (M_PI * 0.5);
    panL = std::cos (theta);
    panR = std::sin (theta);

    const double q = std::max (0.01, std::min (50.0, resonanceQ > 0.0 ? resonanceQ : 0.707));
    if (lpfHz > 0.0 && lpfHz < engineSampleRate * 0.4999) { setBiquadLPF (lpf, lpfHz, q, engineSampleRate); lpf.resetState(); }
    else lpf.bypass = true;
    if (hpfHz > 1.0) { setBiquadHPF (hpf, hpfHz, q, engineSampleRate); hpf.resetState(); }
    else hpf.bypass = true;

    useADSR = hasADSR;
    if (hasADSR)
    {
        atkSamp = std::max (1, (int) (attack  * engineSampleRate));
        decSamp = std::max (1, (int) (decay   * engineSampleRate));
        susLvl  = std::max (0.0, std::min (1.0, sustain));
        relSamp = std::max (1, (int) (release * engineSampleRate));
        noteDurSamp = std::max (1, (int) (durationSec * engineSampleRate));
        envLevel = 0.0;
        stage = Stage::Attack;
    }
    else stage = Stage::None;

    samplesSinceOnset = 0;
    active = true;
}

bool StrudelSampleVoice::render (float* left, float* right,
                                 long long blockStartSample, int numSamples) noexcept
{
    if (! active || src == nullptr) return false;

    const long long offset = startSample - blockStartSample;
    if (offset >= (long long) numSamples) return true;
    int startFrame = (offset > 0) ? (int) offset : 0;

    for (int i = startFrame; i < numSamples; ++i)
    {
        if (pos >= endFrame) { active = false; break; }

        // Envolvente (opcional)
        double env = 1.0;
        if (useADSR)
        {
            switch (stage)
            {
                case Stage::Attack:
                    envLevel += 1.0 / (double) atkSamp;
                    if (envLevel >= 1.0) { envLevel = 1.0; stage = Stage::Decay; }
                    env = envLevel; break;
                case Stage::Decay:
                    envLevel -= (1.0 - susLvl) / (double) decSamp;
                    if (envLevel <= susLvl) { envLevel = susLvl; stage = Stage::Sustain; }
                    env = envLevel; break;
                case Stage::Sustain:
                    env = susLvl;
                    if (samplesSinceOnset >= noteDurSamp) stage = Stage::Release;
                    break;
                case Stage::Release:
                    envLevel -= susLvl / (double) relSamp;
                    if (envLevel <= 0.0) { envLevel = 0.0; stage = Stage::Idle; active = false; }
                    env = std::max (0.0, envLevel); break;
                case Stage::Idle: default:
                    active = false; break;
            }
            if (! active) break;
        }

        double smp = (double) sampleAt (pos);

        // Filtrado en tiempo real (LPF luego HPF)
        if (! lpf.bypass) smp = lpf.process (smp);
        if (! hpf.bypass) smp = hpf.process (smp);

        float out = (float) (smp * env * gain * postgain);

        if (crushBits > 0.0)
        {
            const float levels = (float) std::pow (2.0, crushBits - 1.0);
            out = std::round (out * levels) / levels;
        }

        left[i]  += out * (float) panL;
        right[i] += out * (float) panR;

        pos += rate;
        ++samplesSinceOnset;
    }

    return active;
}

} // namespace strudel
