#include "StrudelJuceCAPI.h"
#include "StrudelEngine.h"
#include "StrudelNote.h"

#include <juce_core/juce_core.h>
#include <cstdio>
#include <cstring>

namespace {
    inline strudel::StrudelEngine* asEngine (StrudelEngineHandle* h) noexcept
    {
        return reinterpret_cast<strudel::StrudelEngine*> (h);
    }
    inline const strudel::StrudelEngine* asEngine (const StrudelEngineHandle* h) noexcept
    {
        return reinterpret_cast<const strudel::StrudelEngine*> (h);
    }

    // JUCE necesita un MessageManager ligado al main thread ANTES de construir
    // AudioDeviceManager. En un host no-JUCE (app Swift) nadie llama
    // initialiseJuce_GUI(), asi que lo hacemos aqui, idempotente y main-thread.
    void ensureJuceMessageManagerInitialised()
    {
        static bool initialised = false;
        if (initialised)
            return;
        if (auto* mm = juce::MessageManager::getInstance())
            mm->setCurrentThreadAsMessageThread();
        initialised = true;
    }
}

extern "C" {

StrudelEngineHandle* strudel_engine_create(void)
{
    ensureJuceMessageManagerInitialised();
    return reinterpret_cast<StrudelEngineHandle*> (new strudel::StrudelEngine());
}

void strudel_engine_destroy(StrudelEngineHandle* handle)
{
    delete asEngine (handle);
}

int strudel_engine_start(StrudelEngineHandle* handle)
{
    if (handle == nullptr)
        return -1;
    asEngine (handle)->start();
    return asEngine (handle)->isRunning() ? 0 : 1;
}

void strudel_engine_stop(StrudelEngineHandle* handle)
{
    if (handle != nullptr)
        asEngine (handle)->stop();
}

int strudel_engine_is_running(const StrudelEngineHandle* handle)
{
    return (handle != nullptr && asEngine (handle)->isRunning()) ? 1 : 0;
}

void strudel_engine_set_test_tone(StrudelEngineHandle* handle, int enabled, float freq_hz)
{
    if (handle != nullptr)
        asEngine (handle)->setTestTone (enabled != 0, freq_hz);
}

void strudel_engine_schedule_synth(StrudelEngineHandle* handle,
                                   double delay_seconds,
                                   const char* waveform,
                                   double freq, double gain,
                                   double attack, double decay,
                                   double sustain, double release,
                                   double duration_sec,
                                   double lpf_hz, double hpf_hz, double resonance_q,
                                   double pan, double crush_bits,
                                   double lpenv_oct, double hpenv_oct,
                                   double postgain, int orbit)
{
    if (handle == nullptr) return;

    strudel::ScheduledNote n;
    n.orbit       = orbit;
    n.wave        = strudel::StrudelVoice::waveFromString (waveform != nullptr ? waveform : "sine");
    n.freq        = freq;
    n.gain        = gain;
    n.attack      = attack;
    n.decay       = decay;
    n.sustain     = sustain;
    n.release     = release;
    n.durationSec = duration_sec;
    n.lpfHz       = lpf_hz;
    n.hpfHz       = hpf_hz;
    n.resonanceQ  = resonance_q;
    n.pan         = pan;
    n.crushBits   = crush_bits;
    n.lpenvOct    = lpenv_oct;
    n.hpenvOct    = hpenv_oct;
    n.postgain    = postgain;

    asEngine (handle)->scheduleSynth (delay_seconds, n);
}

void strudel_engine_all_notes_off(StrudelEngineHandle* handle)
{
    if (handle != nullptr)
        asEngine (handle)->allNotesOff();
}

void strudel_engine_load_sample(StrudelEngineHandle* handle, const char* key,
                                const float* ch0, const float* ch1,
                                int channels, long long frames, double sr)
{
    if (handle == nullptr || key == nullptr) return;
    asEngine (handle)->loadSample (std::string (key), ch0, ch1, channels, frames, sr);
}

int strudel_engine_has_sample(const StrudelEngineHandle* handle, const char* key)
{
    if (handle == nullptr || key == nullptr) return 0;
    return asEngine (handle)->hasSample (std::string (key)) ? 1 : 0;
}

void strudel_engine_schedule_sample(StrudelEngineHandle* handle,
                                    double delay_seconds, const char* key,
                                    double playback_ratio, double gain, double postgain,
                                    double begin_frac, double end_frac,
                                    double lpf_hz, double hpf_hz, double resonance_q,
                                    double pan, double crush_bits,
                                    int has_adsr, double attack, double decay,
                                    double sustain, double release, double duration_sec,
                                    int orbit)
{
    if (handle == nullptr || key == nullptr) return;
    strudel::ScheduledSampleParams p;
    p.playbackRatio = playback_ratio;
    p.gain = gain; p.postgain = postgain;
    p.beginFrac = begin_frac; p.endFrac = end_frac;
    p.lpfHz = lpf_hz; p.hpfHz = hpf_hz; p.resonanceQ = resonance_q;
    p.pan = pan; p.crushBits = crush_bits;
    p.hasADSR = (has_adsr != 0);
    p.attack = attack; p.decay = decay; p.sustain = sustain; p.release = release;
    p.durationSec = duration_sec;
    p.orbit = orbit;
    asEngine (handle)->scheduleSample (delay_seconds, std::string (key), p);
}

void strudel_engine_set_orbit_fx(StrudelEngineHandle* handle, int orbit,
                                 double room, double size,
                                 double delay_wet, double delay_time, double delay_feedback)
{
    if (handle != nullptr)
        asEngine (handle)->setOrbitFX (orbit, room, size, delay_wet, delay_time, delay_feedback);
}

} // extern "C"
