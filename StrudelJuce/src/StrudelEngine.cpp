#include "StrudelEngine.h"

#include <cmath>

namespace strudel {

StrudelEngine::StrudelEngine()
{
    fifoRing.resize (kFifoCap);
    sampleFifoRing.resize (kFifoCap);
}

StrudelEngine::~StrudelEngine()
{
    stop();
}

void StrudelEngine::start()
{
    if (running.load())
        return;

    const juce::String err = deviceManager.initialiseWithDefaultDevices (0, 2);
    if (err.isNotEmpty())
    {
        std::fprintf (stderr, "[StrudelEngine] initialise error: %s\n", err.toRawUTF8());
        return;
    }

    deviceManager.addAudioCallback (this);
    running.store (true);
}

void StrudelEngine::stop()
{
    if (! running.load())
        return;

    deviceManager.removeAudioCallback (this);
    deviceManager.closeAudioDevice();
    running.store (false);
}

bool StrudelEngine::isRunning() const noexcept
{
    return running.load();
}

void StrudelEngine::setTestTone (bool enabled, float freqHz) noexcept
{
    toneFreq.store (juce::jlimit (20.0f, 20000.0f, freqHz));
    toneOn.store (enabled);
}

void StrudelEngine::scheduleSynth (double delaySeconds, const ScheduledNote& note) noexcept
{
    // Convierte delay relativo → índice de muestra absoluto usando el reloj actual.
    const long long now = samplePos.load (std::memory_order_relaxed);
    ScheduledNote n = note;
    n.startSample = now + (long long) (std::max (0.0, delaySeconds) * sampleRate);

    int start1, size1, start2, size2;
    noteFifo.prepareToWrite (1, start1, size1, start2, size2);
    if (size1 > 0)      fifoRing[(size_t) start1] = n;
    else if (size2 > 0) fifoRing[(size_t) start2] = n;
    else { droppedNotes.fetch_add (1); return; }
    noteFifo.finishedWrite (1);
}

void StrudelEngine::allNotesOff() noexcept
{
    // Marca: el audio thread reclama voces al pasar a idle; aquí solo vaciamos
    // pendientes y la FIFO (seguro: se llama con el patrón deteniéndose).
    noteFifo.reset();
    sampleFifo.reset();
    pendingCount = 0;
    samplePendingCount = 0;
    // las voces activas terminan su release naturalmente
}

int StrudelEngine::findFreeVoice() noexcept
{
    for (int i = 0; i < kMaxVoices; ++i)
        if (! voices[(size_t) i].isActive())
            return i;
    // Sin voz libre: roba la voz 0 (voice stealing simple).
    return 0;
}

int StrudelEngine::findFreeSampleVoice() noexcept
{
    for (int i = 0; i < kMaxVoices; ++i)
        if (! sampleVoices[(size_t) i].isActive())
            return i;
    return 0;
}

void StrudelEngine::loadSample (const std::string& key,
                                const float* ch0, const float* ch1,
                                int channels, long long frames, double sr)
{
    if (frames <= 0 || ch0 == nullptr) return;
    SampleData d;
    d.channels = (channels >= 2) ? 2 : 1;
    d.frames   = frames;
    d.sr       = (sr > 0.0) ? sr : 44100.0;
    d.ch0.assign (ch0, ch0 + frames);
    if (d.channels >= 2 && ch1 != nullptr)
        d.ch1.assign (ch1, ch1 + frames);
    sampleBank[key] = std::move (d);
}

bool StrudelEngine::hasSample (const std::string& key) const noexcept
{
    return sampleBank.find (key) != sampleBank.end();
}

void StrudelEngine::scheduleSample (double delaySeconds, const std::string& key,
                                    const ScheduledSampleParams& p) noexcept
{
    auto it = sampleBank.find (key);
    if (it == sampleBank.end()) return;   // sample no cargado: se salta el evento

    const SampleData& src = it->second;
    const long long now = samplePos.load (std::memory_order_relaxed);

    ScheduledSample s;
    s.src = &src;
    s.p   = p;
    s.startSample = now + (long long) (std::max (0.0, delaySeconds) * sampleRate);
    // rate = (srcSR/engineSR) * repitch — mantiene el pitch correcto.
    s.rate = (src.sr / sampleRate) * (p.playbackRatio > 0.0 ? p.playbackRatio : 1.0);

    int start1, size1, start2, size2;
    sampleFifo.prepareToWrite (1, start1, size1, start2, size2);
    if (size1 > 0)      sampleFifoRing[(size_t) start1] = s;
    else if (size2 > 0) sampleFifoRing[(size_t) start2] = s;
    else return;
    sampleFifo.finishedWrite (1);
}

void StrudelEngine::setOrbitFX (int orbit, double room, double size,
                                double delayWet, double delayTime, double delayFeedback) noexcept
{
    if (orbit < 0 || orbit >= kNumOrbits) return;
    orbits[(size_t) orbit].setRoom (room, size);
    orbits[(size_t) orbit].setDelay (delayWet, delayTime, delayFeedback);
}

void StrudelEngine::drainSampleFifo() noexcept
{
    const int ready = sampleFifo.getNumReady();
    if (ready == 0) return;
    int start1, size1, start2, size2;
    sampleFifo.prepareToRead (ready, start1, size1, start2, size2);
    auto append = [this] (const ScheduledSample& s)
    {
        if (samplePendingCount < kPending)
            samplePending[(size_t) samplePendingCount++] = s;
    };
    for (int i = 0; i < size1; ++i) append (sampleFifoRing[(size_t) (start1 + i)]);
    for (int i = 0; i < size2; ++i) append (sampleFifoRing[(size_t) (start2 + i)]);
    sampleFifo.finishedRead (ready);
}

void StrudelEngine::drainFifoIntoPending() noexcept
{
    const int ready = noteFifo.getNumReady();
    if (ready == 0) return;

    int start1, size1, start2, size2;
    noteFifo.prepareToRead (ready, start1, size1, start2, size2);

    auto append = [this] (const ScheduledNote& n)
    {
        if (pendingCount < kPending)
            pending[(size_t) pendingCount++] = n;
    };
    for (int i = 0; i < size1; ++i) append (fifoRing[(size_t) (start1 + i)]);
    for (int i = 0; i < size2; ++i) append (fifoRing[(size_t) (start2 + i)]);

    noteFifo.finishedRead (ready);
}

void StrudelEngine::audioDeviceAboutToStart (juce::AudioIODevice* device)
{
    sampleRate = device->getCurrentSampleRate();
    if (sampleRate <= 0.0) sampleRate = 48000.0;
    phase = 0.0;
    samplePos.store (0);
    pendingCount = 0;
    samplePendingCount = 0;
    const int maxBlock = device->getCurrentBufferSizeSamples();
    for (auto& ob : orbits) ob.prepare (sampleRate, std::max (256, maxBlock));
}

void StrudelEngine::audioDeviceStopped() {}

void StrudelEngine::audioDeviceError (const juce::String& errorMessage)
{
    std::fprintf (stderr, "[StrudelEngine] device error: %s\n", errorMessage.toRawUTF8());
}

void StrudelEngine::audioDeviceIOCallbackWithContext (const float* const* /*in*/,
                                                     int /*numIn*/,
                                                     float* const* outputChannelData,
                                                     int numOutputChannels,
                                                     int numSamples,
                                                     const juce::AudioIODeviceCallbackContext& /*ctx*/)
{
    // Limpia salida.
    for (int ch = 0; ch < numOutputChannels; ++ch)
        if (outputChannelData[ch] != nullptr)
            juce::FloatVectorOperations::clear (outputChannelData[ch], numSamples);

    const long long blockStart = samplePos.load (std::memory_order_relaxed);
    const long long blockEnd   = blockStart + numSamples;

    // 1) Drena la FIFO a la cola de pendientes (audio-owned).
    drainFifoIntoPending();

    // 2) Dispara las notas cuya ventana de inicio cae en/antes de este bloque.
    //    Las futuras permanecen en `pending` para el siguiente bloque.
    int w = 0;
    for (int r = 0; r < pendingCount; ++r)
    {
        const ScheduledNote& n = pending[(size_t) r];
        if (n.startSample < blockEnd)
        {
            const int vi = findFreeVoice();
            voices[(size_t) vi].trigger (
                n.wave, n.freq, n.gain,
                n.attack, n.decay, n.sustain, n.release,
                n.durationSec, sampleRate,
                n.startSample,
                n.lpfHz, n.hpfHz, n.resonanceQ,
                n.pan, n.crushBits, n.lpenvOct, n.hpenvOct, n.postgain);
            voices[(size_t) vi].setOrbit (n.orbit);
        }
        else
        {
            pending[(size_t) w++] = n;   // aún futura: conservar
        }
    }
    pendingCount = w;

    // 2b) Samples: drena y dispara los vencidos.
    drainSampleFifo();
    int ws = 0;
    for (int r = 0; r < samplePendingCount; ++r)
    {
        const ScheduledSample& s = samplePending[(size_t) r];
        if (s.startSample < blockEnd)
        {
            const int vi = findFreeSampleVoice();
            sampleVoices[(size_t) vi].trigger (
                s.src, s.rate, s.p.gain, s.p.postgain,
                s.p.beginFrac, s.p.endFrac,
                s.p.lpfHz, s.p.hpfHz, s.p.resonanceQ,
                s.p.pan, s.p.crushBits,
                s.p.hasADSR, s.p.attack, s.p.decay, s.p.sustain, s.p.release, s.p.durationSec,
                sampleRate, s.startSample);
            sampleVoices[(size_t) vi].setOrbit (s.p.orbit);
        }
        else samplePending[(size_t) ws++] = s;
    }
    samplePendingCount = ws;

    float* left  = (numOutputChannels > 0) ? outputChannelData[0] : nullptr;
    float* right = (numOutputChannels > 1) ? outputChannelData[1] : left;
    if (left == nullptr) { samplePos.store (blockEnd); return; }
    if (right == nullptr) right = left;

    // 3) Render de voces en el buffer de SU orbit (no directo a la salida).
    for (auto& ob : orbits) ob.clear (numSamples);

    auto clampOrbit = [] (int o) { return (o < 0) ? 0 : (o >= kNumOrbits ? kNumOrbits - 1 : o); };

    for (auto& v : voices)
        if (v.isActive())
        {
            auto& ob = orbits[(size_t) clampOrbit (v.orbit())];
            v.render (ob.bufL (numSamples), ob.bufR (numSamples), blockStart, numSamples, sampleRate);
        }
    for (auto& sv : sampleVoices)
        if (sv.isActive())
        {
            auto& ob = orbits[(size_t) clampOrbit (sv.orbit())];
            sv.render (ob.bufL (numSamples), ob.bufR (numSamples), blockStart, numSamples);
        }

    // 4) Cada orbit aplica reverb+delay y suma a la salida (colas incluidas).
    for (auto& ob : orbits)
        ob.processAndMix (left, right, numSamples);

    // 5) Test tone (Fase 0) — directo a la salida (sin FX).
    if (toneOn.load())
    {
        const double freq = (double) toneFreq.load();
        const double inc  = 2.0 * M_PI * freq / sampleRate;
        const float  amp  = 0.2f;
        for (int i = 0; i < numSamples; ++i)
        {
            const float s = amp * (float) std::sin (phase);
            phase += inc;
            if (phase >= 2.0 * M_PI) phase -= 2.0 * M_PI;
            left[i]  += s;
            if (right != left) right[i] += s;
        }
    }

    samplePos.store (blockEnd, std::memory_order_relaxed);
}

} // namespace strudel
