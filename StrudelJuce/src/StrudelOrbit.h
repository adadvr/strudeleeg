#pragma once

// ---------------------------------------------------------------------------
// OrbitBus — bus de efectos por orbit (equivalente a OrbitBus del backend
// AVAudio): reverb (Freeverb via juce::Reverb) + delay estéreo con feedback.
// Las voces se renderizan en el buffer del orbit; luego este aplica los FX y
// se suma a la salida. Parámetros "last event wins per orbit".
// ---------------------------------------------------------------------------

#include <juce_audio_basics/juce_audio_basics.h>
#include <vector>
#include <algorithm>
#include <cmath>

namespace strudel {

class OrbitBus
{
public:
    void prepare (double sr, int maxBlock)
    {
        sampleRate = sr;
        reverb.setSampleRate (sr);
        // Delay ring de hasta 2 s.
        dlSize = std::max (1, (int) (sr * 2.0));
        dlL.assign ((size_t) dlSize, 0.0f);
        dlR.assign ((size_t) dlSize, 0.0f);
        dlPos = 0;
        scratchL.assign ((size_t) maxBlock, 0.0f);
        scratchR.assign ((size_t) maxBlock, 0.0f);
    }

    // Parámetros desde el scheduler (control thread → atomics simples por doble).
    void setRoom (double wet, double size) noexcept { roomWet = wet; sizeVal = size; dirty = true; }
    void setDelay (double wet, double time, double fb) noexcept
    {
        delayWet = wet;
        if (time > 0.0) delayTime = time;
        if (fb   >= 0.0) delayFb  = fb;
    }

    float* bufL (int n) { ensure (n); return scratchL.data(); }
    float* bufR (int n) { ensure (n); return scratchR.data(); }

    void clear (int n)
    {
        ensure (n);
        std::fill (scratchL.begin(), scratchL.begin() + n, 0.0f);
        std::fill (scratchR.begin(), scratchR.begin() + n, 0.0f);
        active = false;
    }

    void markActive() noexcept { active = true; }
    bool isActive() const noexcept { return active; }

    // Aplica reverb + delay in-place sobre el scratch y suma a outL/outR.
    void processAndMix (float* outL, float* outR, int n)
    {
        if (dirty)
        {
            juce::Reverb::Parameters p;
            p.roomSize = (float) std::max (0.0, std::min (1.0, sizeVal > 0.0 ? sizeVal : 0.5));
            p.wetLevel = (float) std::max (0.0, std::min (1.0, roomWet));
            // Send paralelo (como Strudel): la señal seca queda SIEMPRE a full y el
            // reverb se SUMA encima según roomWet. Antes usábamos dryLevel = 1-wet
            // (crossfade), que a room alto apagaba y lavaba toda la mezcla del orbit.
            p.dryLevel = 1.0f;
            p.width    = 1.0f;
            p.damping  = 0.3f;
            reverb.setParameters (p);
            dirty = false;
        }

        float* L = scratchL.data();
        float* R = scratchR.data();

        // Reverb (wet+dry según parámetros). Si roomWet=0 → passthrough.
        if (roomWet > 0.0)
            reverb.processStereo (L, R, n);

        // Delay estéreo con feedback y mezcla wet.
        if (delayWet > 0.0)
        {
            const int delaySamples = std::max (1, std::min (dlSize - 1, (int) (delayTime * sampleRate)));
            const float wet = (float) std::min (1.0, delayWet);
            const float fb  = (float) std::max (0.0, std::min (0.98, delayFb));
            for (int i = 0; i < n; ++i)
            {
                const int rp = (dlPos - delaySamples + dlSize) % dlSize;
                const float dL = dlL[(size_t) rp];
                const float dR = dlR[(size_t) rp];
                const float inL = L[i];
                const float inR = R[i];
                dlL[(size_t) dlPos] = inL + dL * fb;
                dlR[(size_t) dlPos] = inR + dR * fb;
                dlPos = (dlPos + 1) % dlSize;
                L[i] = inL + wet * dL;
                R[i] = inR + wet * dR;
            }
        }

        for (int i = 0; i < n; ++i) { outL[i] += L[i]; outR[i] += R[i]; }
    }

private:
    void ensure (int n)
    {
        if ((int) scratchL.size() < n) { scratchL.resize ((size_t) n, 0.0f); scratchR.resize ((size_t) n, 0.0f); }
    }

    double sampleRate { 48000.0 };
    juce::Reverb reverb;
    std::vector<float> scratchL, scratchR;
    std::vector<float> dlL, dlR;
    int dlSize { 1 }, dlPos { 0 };

    double roomWet { 0.0 }, sizeVal { 0.5 };
    double delayWet { 0.0 }, delayTime { 0.25 }, delayFb { 0.4 };
    bool dirty { true }, active { false };
};

} // namespace strudel
