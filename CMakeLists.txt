cmake_minimum_required(VERSION 3.21)

project(mac_cleaner
    VERSION 0.1.0
    DESCRIPTION "macOS disk cleanup / storage optimization tool"
    LANGUAGES CXX)

if(NOT APPLE)
    message(WARNING "mac-cleaner targets macOS; building on ${CMAKE_SYSTEM_NAME} for development/testing only.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

option(MACCLEANER_BUILD_TESTS "Build the test suite" ON)
option(MACCLEANER_USE_NATIVE_TRASH "Use NSFileManager to move items to Trash on macOS (falls back to remove_all otherwise)" ON)
option(MACCLEANER_WARNINGS_AS_ERRORS "Treat warnings as errors" OFF)

add_library(maccleaner_warnings INTERFACE)
target_compile_options(maccleaner_warnings INTERFACE
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
    $<$<BOOL:${MACCLEANER_WARNINGS_AS_ERRORS}>:-Werror>
)

# --- core library -------------------------------------------------------
set(MACCLEANER_CORE_SOURCES
    src/format.cpp
    src/safety.cpp
    src/scanner.cpp
    src/cleaner.cpp
    src/cli.cpp
)

set(MACCLEANER_APPLE_SOURCES)
if(APPLE AND MACCLEANER_USE_NATIVE_TRASH)
    enable_language(OBJCXX)
    list(APPEND MACCLEANER_APPLE_SOURCES src/platform/trash_mac.mm)
else()
    list(APPEND MACCLEANER_APPLE_SOURCES src/platform/trash_fallback.cpp)
endif()

add_library(maccleaner_core STATIC
    ${MACCLEANER_CORE_SOURCES}
    ${MACCLEANER_APPLE_SOURCES}
)
target_include_directories(maccleaner_core PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_link_libraries(maccleaner_core PRIVATE maccleaner_warnings)
target_compile_definitions(maccleaner_core PUBLIC
    MACCLEANER_NATIVE_TRASH=$<BOOL:$<AND:$<BOOL:${APPLE}>,$<BOOL:${MACCLEANER_USE_NATIVE_TRASH}>>>
)

if(APPLE AND MACCLEANER_USE_NATIVE_TRASH)
    find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
    target_link_libraries(maccleaner_core PRIVATE ${FOUNDATION_FRAMEWORK})
    set_source_files_properties(src/platform/trash_mac.mm PROPERTIES
        COMPILE_FLAGS "-fobjc-arc"
    )
endif()

# --- executable -----------------------------------------------------------
add_executable(mac_cleaner src/main.cpp)
target_link_libraries(mac_cleaner PRIVATE maccleaner_core maccleaner_warnings)

# --- tests ------------------------------------------------------------
if(MACCLEANER_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
