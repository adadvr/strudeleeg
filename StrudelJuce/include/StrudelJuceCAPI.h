#pragma once

// ---------------------------------------------------------------------------
// StrudelJuceCAPI — superficie C pura del tercer motor de audio (JUCE) de
// strudeleeg. Sin dependencias C++/JUCE en el header: Swift lo importa via
// module.modulemap y llama estas funciones directamente.
//
// AGNOSTICO DE PLATAFORMA a proposito: hoy solo se compila/enlaza para macOS,
// pero nada de esta API es macOS-only. La migracion a iOS debe ser solo build +
// AVAudioSession, sin tocar esta superficie (ver StrudelJuce/README.md).
//
// Fase 0: solo lifecycle + test tone. El resto de la API (schedule_synth,
// schedule_sample, orbit FX, duck, load_sample) se agrega en Fases 2-4.
// ---------------------------------------------------------------------------

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StrudelEngineHandle StrudelEngineHandle;

// Lifecycle. Crear/destruir una sola vez por motor (el adapter Swift lo posee).
StrudelEngineHandle* strudel_engine_create(void);
void                 strudel_engine_destroy(StrudelEngineHandle* handle);

// Abrir/cerrar el device de audio por defecto. start() retorna 0 = ok, != 0 = error.
int  strudel_engine_start(StrudelEngineHandle* handle);
void strudel_engine_stop (StrudelEngineHandle* handle);
int  strudel_engine_is_running(const StrudelEngineHandle* handle);

// Test tone de la Fase 0. `enabled` = 0/1. `freq_hz` clampeado a [20, 20000].
// Prueba end-to-end de que la lib linka y produce audio desde Swift.
void strudel_engine_set_test_tone(StrudelEngineHandle* handle, int enabled, float freq_hz);

// ---- Fase 2: scheduling de synth ----
// Agenda una voz de oscilador. Llamar desde el control thread (scheduler Swift),
// NO desde el audio thread. delay_seconds: cuánto en el futuro debe sonar
// (relativo a "ahora"); el engine lo convierte a tiempo de muestra absoluto.
//
// waveform: "sine" | "sawtooth" | "square" | "triangle".
// Sentinelas: lpf_hz/hpf_hz <= 0 → sin filtro; resonance_q <= 0 → 0.707;
//             pan < 0 → centro; crush_bits = 0 → sin bitcrush.
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
                                   double postgain, int orbit);

// Corta todas las voces / vacía la cola agendada (al parar o cambiar patrón).
void strudel_engine_all_notes_off(StrudelEngineHandle* handle);

// ---- Fase 3: samples ----
// Carga PCM float en el banco bajo `key`. Llamar desde el control thread ANTES
// de reproducir (aloca). channels 1 o 2; ch1 puede ser NULL si mono. frames =
// número de muestras por canal. sr = sample rate del archivo.
void strudel_engine_load_sample(StrudelEngineHandle* handle, const char* key,
                                const float* ch0, const float* ch1,
                                int channels, long long frames, double sr);
int  strudel_engine_has_sample(const StrudelEngineHandle* handle, const char* key);

// Agenda la reproducción de un sample cargado. playback_ratio = noteRate*speed
// (repitch); el engine multiplica por srcSR/engineSR. begin/end en 0..1 (<0 =
// sin slice). has_adsr=1 aplica envolvente. Sentinelas de filtro/pan/crush como
// en schedule_synth.
void strudel_engine_schedule_sample(StrudelEngineHandle* handle,
                                    double delay_seconds, const char* key,
                                    double playback_ratio, double gain, double postgain,
                                    double begin_frac, double end_frac,
                                    double lpf_hz, double hpf_hz, double resonance_q,
                                    double pan, double crush_bits,
                                    int has_adsr, double attack, double decay,
                                    double sustain, double release, double duration_sec,
                                    int orbit);

// ---- Fase 4: FX de orbit ----
// Ajusta reverb+delay de un orbit (0..7). "last event wins". room/size 0..1;
// delay_wet 0..1; delay_time en segundos; delay_feedback 0..1.
void strudel_engine_set_orbit_fx(StrudelEngineHandle* handle, int orbit,
                                 double room, double size,
                                 double delay_wet, double delay_time, double delay_feedback);

#ifdef __cplusplus
}
#endif
