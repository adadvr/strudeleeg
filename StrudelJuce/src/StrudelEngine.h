#pragma once

#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_core/juce_core.h>

#include "StrudelVoice.h"
#include "StrudelNote.h"
#include "StrudelSample.h"
#include "StrudelOrbit.h"

#include <atomic>
#include <array>
#include <vector>
#include <string>
#include <unordered_map>

namespace strudel {

// Motor de audio JUCE para la columna [juce] de strudeleeg.
//
// Fase 2: pool polifónico de StrudelVoice + FIFO SPSC lock-free de notas +
// reloj por índice de muestra. El control thread (Swift scheduler) agenda notas
// con un delay en segundos; el audio thread drena las vencidas, dispara voces y
// mezcla su salida. Conserva el test tone de Fase 0.
class StrudelEngine : public juce::AudioIODeviceCallback
{
public:
    StrudelEngine();
    ~StrudelEngine() override;

    // Lifecycle
    void start();
    void stop();
    bool isRunning() const noexcept;

    // Test tone (Fase 0)
    void setTestTone (bool enabled, float freqHz = 440.0f) noexcept;

    // Fase 2 — scheduling de synth. Llamado desde el control thread (NO audio).
    // delaySeconds: cuánto en el futuro debe sonar, relativo a "ahora". El engine
    // lo convierte a índice de muestra absoluto (nowSample + delay*sr).
    void scheduleSynth (double delaySeconds, const ScheduledNote& note) noexcept;

    // Corta todas las voces y vacía la cola (al parar/cambiar patrón).
    void allNotesOff() noexcept;

    // Fase 3 — samples. loadSample copia el PCM al banco (control thread, con el
    // patrón detenido: aloca). channels 1 o 2; ch1 puede ser null si mono.
    void loadSample (const std::string& key,
                     const float* ch0, const float* ch1,
                     int channels, long long frames, double sr);
    bool hasSample (const std::string& key) const noexcept;

    // Agenda un sample. playbackRatio = noteRate*speed (el engine multiplica por
    // src->sr/engineSR). begin/end en 0..1. Filtros por voz en tiempo real.
    void scheduleSample (double delaySeconds, const std::string& key,
                         const ScheduledSampleParams& p) noexcept;

    // Fase 4 — FX de orbit (reverb + delay). "last event wins per orbit".
    // Llamado desde el control thread; el audio thread aplica los parámetros.
    void setOrbitFX (int orbit, double room, double size,
                     double delayWet, double delayTime, double delayFeedback) noexcept;

    // juce::AudioIODeviceCallback ------------------------------------------
    void audioDeviceIOCallbackWithContext (const float* const* inputChannelData,
                                           int numInputChannels,
                                           float* const* outputChannelData,
                                           int numOutputChannels,
                                           int numSamples,
                                           const juce::AudioIODeviceCallbackContext& context) override;
    void audioDeviceAboutToStart (juce::AudioIODevice* device) override;
    void audioDeviceStopped() override;
    void audioDeviceError (const juce::String& errorMessage) override;

private:
    static constexpr int kMaxVoices  = 64;
    static constexpr int kPending    = 1024;   // notas agendadas-no-vencidas (audio-owned)
    static constexpr int kFifoCap    = 2048;   // handoff control→audio
    static constexpr int kNumOrbits  = 8;      // orbit buses (índice 0..7)

    juce::AudioDeviceManager deviceManager;

    std::atomic<bool>  running  { false };
    std::atomic<bool>  toneOn   { false };
    std::atomic<float> toneFreq { 440.0f };
    double sampleRate { 48000.0 };
    double phase      { 0.0 };

    // Reloj por muestra (leído por el control thread para calcular startSample).
    std::atomic<long long> samplePos { 0 };

    // Pool de voces (audio-thread-owned).
    std::array<StrudelVoice, kMaxVoices> voices;

    // FIFO SPSC de handoff (control → audio).
    juce::AbstractFifo     noteFifo { kFifoCap };
    std::vector<ScheduledNote> fifoRing;   // tamaño kFifoCap
    std::atomic<int>       droppedNotes { 0 };

    // Cola de pendientes propiedad del audio thread (agendadas, aún no vencidas).
    std::array<ScheduledNote, kPending> pending;
    int pendingCount { 0 };

    // ── Samples (Fase 3) ──────────────────────────────────────────────────
    std::unordered_map<std::string, SampleData> sampleBank;   // control-thread mutado antes de play
    std::array<StrudelSampleVoice, kMaxVoices> sampleVoices;
    juce::AbstractFifo         sampleFifo { kFifoCap };
    std::vector<ScheduledSample> sampleFifoRing;   // tamaño kFifoCap
    std::array<ScheduledSample, kPending> samplePending;
    int samplePendingCount { 0 };

    // Orbit buses (Fase 4).
    std::array<OrbitBus, kNumOrbits> orbits;

    int  findFreeVoice() noexcept;
    int  findFreeSampleVoice() noexcept;
    void drainFifoIntoPending() noexcept;
    void drainSampleFifo() noexcept;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (StrudelEngine)
};

} // namespace strudel
