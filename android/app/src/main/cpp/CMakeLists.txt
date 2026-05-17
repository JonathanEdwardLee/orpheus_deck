cmake_minimum_required(VERSION 3.22.1)
project(orpheus_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
    oboe
    GIT_REPOSITORY https://github.com/google/oboe.git
    GIT_TAG 1.10.0
)
FetchContent_MakeAvailable(oboe)

add_library(orpheus_native SHARED
    native_engine.cpp
    oboe_engine.cpp
    duplex_engine.cpp
    playback_engine.cpp
    overdub_engine.cpp
    mixer_engine.cpp
    click_backing.cpp
    timing_analysis.cpp
    ring_buffer.cpp
    wav_writer.cpp
    wav_reader.cpp
    wav_test_tone.cpp
)

target_include_directories(orpheus_native PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(orpheus_native
    PRIVATE
    oboe
    log
    android
)

target_compile_options(orpheus_native PRIVATE -Wall -Wextra)
