#pragma once

#include "StrudelVoice.h"

namespace strudel {

// Nota agendada (POD, trivially copyable) que viaja del control thread (Swift
// scheduler) al audio thread vía FIFO SPSC. startSample = índice de muestra
// absoluto del engine en el que debe empezar a sonar.
struct ScheduledNote
{
    long long startSample { 0 };
    int    orbit { 1 };
    StrudelVoice::Wave wave { StrudelVoice::Wave::Sine };
    double freq { 440.0 };
    double gain { 1.0 };
    double attack { 0.01 };
    double decay { 0.1 };
    double sustain { 0.8 };
    double release { 0.1 };
    double durationSec { 0.5 };
    double lpfHz { -1.0 };       // <=0 → sin LPF
    double hpfHz { -1.0 };       // <=0 → sin HPF
    double resonanceQ { -1.0 };  // <=0 → 0.707
    double pan { -1.0 };         // <0 → centro
    double crushBits { 0.0 };
    double lpenvOct { 0.0 };
    double hpenvOct { 0.0 };
    double postgain { 1.0 };
};

} // namespace strudel
