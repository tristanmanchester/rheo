cmake_minimum_required(VERSION 3.20)
project(rheo VERSION 0.2.0 LANGUAGES NONE)
# Cargo and the shell entrypoints own compilation/linking. CMake is a convenience
# wrapper, not a second set of compiler settings that can drift from release builds.
find_program(CARGO_EXECUTABLE cargo REQUIRED)
option(SN_SANITIZE "Instrument C test harnesses/reference with ASan and UBSan" ON)
add_custom_target(rheo_core ALL
    COMMAND "${CARGO_EXECUTABLE}" build --locked --offline --release -p rheo-ffi --lib
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL)
include(CTest)
if(BUILD_TESTING)
    if(SN_SANITIZE)
        set(SN_SAN_VALUE 1)
    else()
        set(SN_SAN_VALUE 0)
    endif()
    add_test(NAME portable-and-abi
        COMMAND "${CMAKE_COMMAND}" -E env "SANITIZE=${SN_SAN_VALUE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test.sh")
    add_custom_target(core_bench
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/bench.sh"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        USES_TERMINAL)
endif()
if(APPLE)
    add_custom_target(Rheo ALL
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build.sh"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        USES_TERMINAL)
endif()
