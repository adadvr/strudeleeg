cmake_minimum_required(VERSION 3.25)

# ----------------------------------------------------------------------------
# StrudelJuce — tercer motor de audio (C++/JUCE 8) de strudeleeg, columna [juce].
# Produce libStrudelJuce.a. El script scripts/build_macos.sh combina esta lib
# con los modulos JUCE en un .xcframework consumible por SPM.
#
# Alcance actual: macOS arm64. iOS-READY: pasar el toolchain ios-cmake
# (-DCMAKE_TOOLCHAIN_FILE=cmake/ios-cmake/ios.toolchain.cmake -DPLATFORM=OS64)
# compila el slice iOS SIN cambios de codigo (ver README.md).
# ----------------------------------------------------------------------------

project(StrudelJuce
        VERSION 0.1.0
        DESCRIPTION "JUCE audio backend for strudeleeg [juce] column"
        LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Deployment target. macOS por defecto; el toolchain iOS lo sobreescribe.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS deployment")
    endif()
endif()

# ----------------------------------------------------------------------------
# JUCE 8.0.4 via FetchContent (shallow). Primer build baja ~300MB, cacheado en
# build/_deps/. Se puede apuntar a una copia local con -DJUCE_SOURCE_DIR=...
# ----------------------------------------------------------------------------
include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

if(JUCE_SOURCE_DIR)
    add_subdirectory(${JUCE_SOURCE_DIR} ${CMAKE_BINARY_DIR}/juce-build)
else()
    FetchContent_Declare(
        JUCE
        GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG        8.0.4
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(JUCE)
endif()

# ----------------------------------------------------------------------------
# Libreria estatica. GLOB recursivo de src/ (cada subsistema en su carpeta).
# ----------------------------------------------------------------------------
file(GLOB_RECURSE STRUDEL_JUCE_SOURCES
    CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp"
)
add_library(StrudelJuce STATIC ${STRUDEL_JUCE_SOURCES})

target_include_directories(StrudelJuce PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(StrudelJuce
    PRIVATE
        juce::juce_audio_basics
        juce::juce_audio_devices
        juce::juce_audio_formats
        juce::juce_dsp
        juce::juce_core
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_warning_flags
)
# NOTA: NO usamos juce_recommended_lto_flags. La LTO produce objetos en bitcode
# LLVM dentro de la .a, y `xcodebuild -create-xcframework` los rechaza
# ("Unknown header: 0xb17c0de"). Sin LTO la lib queda en mach-o arm64 nativo.

target_compile_definitions(StrudelJuce PUBLIC
    JUCE_MODAL_LOOPS_PERMITTED=0
    JUCE_STANDALONE_APPLICATION=0
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
    JUCE_DISABLE_AUDIO_MIXING_WITH_OTHER_APPS=1
)

set_target_properties(StrudelJuce PROPERTIES
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")

message(STATUS "StrudelJuce: C++${CMAKE_CXX_STANDARD}, system=${CMAKE_SYSTEM_NAME}")
