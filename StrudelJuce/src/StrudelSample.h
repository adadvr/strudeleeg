#pragma once

// ---------------------------------------------------------------------------
// StrudelSampleVoice — reproducción de samples con repitch/speed, slicing
// begin/end, y filtrado LPF/HPF EN TIEMPO REAL por muestra (mejora sobre el
// backend AVAudio, que filtra el buffer completo con coeficientes constantes en
// un preproceso). Interpolación lineal para el resampleo.
// ---------------------------------------------------------------------------

#include "StrudelDSP.h"
#include <vector>
#include <algorithm>

namespace strudel {

// PCM decodificado de un sample (hasta 2 canales). Propiedad del engine.
struct SampleData
{
    std::vector<float> ch0;
    std::vector<float> ch1;
    int       channels { 1 };
    long long frames   { 0 };
    double    sr       { 44100.0 };
};

// Parámetros de scheduling de sample (sin el buffer; el engine resuelve la key).
struct ScheduledSampleParams
{
    double playbackRatio { 1.0 };  // noteRate * speed (repitch)
    double gain { 1.0 };
    double postgain { 1.0 };
    double beginFrac { -1.0 };
    double endFrac { -1.0 };
    double lpfHz { -1.0 };
    double hpfHz { -1.0 };
    double resonanceQ { -1.0 };
    double pan { -1.0 };
    double crushBits { 0.0 };
    bool   hasADSR { false };
    double attack { 0.01 }, decay { 0.1 }, sustain { 0.8 }, release { 0.1 };
    double durationSec { 0.5 };
    int    orbit { 1 };
};

// POD que viaja por la FIFO al audio thread (src ya resuelto, rate ya calculado).
struct ScheduledSample
{
    long long startSample { 0 };
    const SampleData* src { nullptr };
    double rate { 1.0 };
    ScheduledSampleParams p;
};

class StrudelSampleVoice
{
public:
    StrudelSampleVoice() = default;

    bool isActive() const noexcept { return active; }
    long long startSampleIndex() const noexcept { return startSample; }
    void setOrbit (int o) noexcept { orbitIdx = o; }
    int  orbit() const noexcept { return orbitIdx; }

    // Dispara la reproducción de `src`. rate = (srcSR/engineSR)*noteRate*speed.
    // begin/end en 0..1 (slice). lpfHz/hpfHz <=0 → sin filtro. resonanceQ<=0→0.707.
    // pan<0 → centro. crushBits=0 → sin crush. hasADSR aplica envolvente.
    void trigger (const SampleData* src,
                  double rate, double gain, double postgain,
                  double beginFrac, double endFrac,
                  double lpfHz, double hpfHz, double resonanceQ,
                  double pan, double crushBits,
                  bool hasADSR, double attack, double decay, double sustain,
                  double release, double durationSec,
                  double engineSampleRate,
                  long long startSampleAbs) noexcept;

    bool render (float* left, float* right,
                 long long blockStartSample, int numSamples) noexcept;

private:
    enum class Stage { Attack, Decay, Sustain, Release, Idle, None };

    bool   active { false };
    int    orbitIdx { 1 };
    const SampleData* src { nullptr };

    double pos { 0.0 };       // posición fraccional en frames de origen
    double rate { 1.0 };      // paso por muestra de salida
    double endFrame { 0.0 };  // límite superior (end slice)
    long long startSample { 0 };

    double gain { 1.0 }, postgain { 1.0 };
    double panL { 0.7071 }, panR { 0.7071 };
    double crushBits { 0.0 };

    Biquad lpf, hpf;

    // ADSR opcional
    bool   useADSR { false };
    Stage  stage { Stage::None };
    double envLevel { 0.0 }, susLvl { 1.0 };
    int    atkSamp { 1 }, decSamp { 1 }, relSamp { 1 }, noteDurSamp { 1 };
    long long samplesSinceOnset { 0 };

    inline float sampleAt (double p) const noexcept;
};

} // namespace strudel
