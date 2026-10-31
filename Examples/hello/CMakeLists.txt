cmake_minimum_required(VERSION 3.20)
project(hello LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(greeter src/greeter.cpp)
target_include_directories(greeter PUBLIC src)

add_executable(hello src/main.cpp)
target_link_libraries(hello PRIVATE greeter)

enable_testing()
add_executable(greeter_test tests/greeter_test.cpp)
target_link_libraries(greeter_test PRIVATE greeter)
add_test(NAME greeting COMMAND greeter_test greeting)
add_test(NAME shout COMMAND greeter_test shout)
