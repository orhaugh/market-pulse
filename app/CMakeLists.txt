# market-pulse native app: a custom stateful operator built against the
# installed clink package, the way any downstream consumer builds.
#
#   cmake -S app -B app/build -DCMAKE_PREFIX_PATH=$PWD/.clink/prefix
#   cmake --build app/build --parallel
#   ./app/build/mp_anomaly --in data/trades.ndjson --out out/alerts.ndjson
#   ctest --test-dir app/build      # runs the clink::test_support tests

cmake_minimum_required(VERSION 3.24)
project(market_pulse_app LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(clink REQUIRED COMPONENTS core test_support)

add_executable(mp_anomaly src/mp_anomaly.cpp)
target_link_libraries(mp_anomaly PRIVATE clink::core)

enable_testing()
add_executable(spike_detector_test tests/spike_detector_test.cpp)
target_include_directories(spike_detector_test PRIVATE src)
target_link_libraries(spike_detector_test PRIVATE clink::core clink::test_support)
add_test(NAME spike_detector_test COMMAND spike_detector_test)
