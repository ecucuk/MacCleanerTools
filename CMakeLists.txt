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
option(MACCLEANER_BUILD_GUI "Build the AppKit GUI app (macOS only)" ON)
option(MACCLEANER_USE_NATIVE_TRASH "Use NSFileManager to move items to Trash on macOS (falls back to remove_all otherwise)" ON)
option(MACCLEANER_WARNINGS_AS_ERRORS "Treat warnings as errors" OFF)

# Both the native Trash backend and the GUI are Objective-C++. Enabled once
# here rather than inside either feature's own block, so turning one off does
# not knock out the language the other still needs.
if(APPLE AND (MACCLEANER_USE_NATIVE_TRASH OR MACCLEANER_BUILD_GUI))
    enable_language(OBJCXX)
endif()

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
    src/bigfiles.cpp
    src/processes.cpp
    src/optimizer.cpp
    src/cli.cpp
)

set(MACCLEANER_APPLE_SOURCES)
if(APPLE AND MACCLEANER_USE_NATIVE_TRASH)
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

# --- GUI app --------------------------------------------------------------
# A second front end over the same maccleaner_core: no duplicated scan, safety
# or delete logic, and no new dependencies beyond system frameworks.
if(APPLE AND MACCLEANER_BUILD_GUI)
    # The activity window is SwiftUI. CMake only supports Swift with the Ninja
    # and Xcode generators, so configure with -G Ninja; failing at configure
    # time beats a cryptic "unknown language" error mid-build.
    if(NOT CMAKE_GENERATOR MATCHES "Ninja|Xcode")
        message(FATAL_ERROR
            "MACCLEANER_BUILD_GUI needs Swift, which CMake only supports with the "
            "Ninja or Xcode generators (got: ${CMAKE_GENERATOR}). Configure with "
            "-G Ninja, or pass -DMACCLEANER_BUILD_GUI=OFF for a CLI-only build.")
    endif()
    enable_language(Swift)

    # Swift cannot be mixed with C++/ObjC++ sources in one target, so the
    # SwiftUI layer is its own static library. Its @objc API surfaces in a
    # compiler-generated header the ObjC++ side imports; -static means the
    # generated header declares SWIFT_CLASS without dllexport-style noise.
    set(MACCLEANER_VIZ_HEADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/viz-include")
    add_library(maccleaner_viz STATIC
        src/gui/viz/MCActivityWindow.swift
    )
    target_compile_options(maccleaner_viz PRIVATE
        -emit-objc-header
        -emit-objc-header-path "${MACCLEANER_VIZ_HEADER_DIR}/MacCleanerViz-Swift.h"
    )

    # The generated -Swift.h is a side effect of maccleaner_viz's compile step,
    # invisible to the build graph: neither a link dependency nor
    # add_dependencies() stops Ninja from compiling MacCleaner's .mm files
    # before the header exists (compile steps only wait on *known generated
    # files*). Copying it via a custom command turns it into exactly that, and
    # listing the copy as a GENERATED source of MacCleaner gates every object
    # compile of the app on it.
    set(MACCLEANER_VIZ_HEADER_STAGED "${CMAKE_CURRENT_BINARY_DIR}/viz-header/MacCleanerViz-Swift.h")
    add_custom_command(OUTPUT "${MACCLEANER_VIZ_HEADER_STAGED}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${MACCLEANER_VIZ_HEADER_DIR}/MacCleanerViz-Swift.h"
                "${MACCLEANER_VIZ_HEADER_STAGED}"
        DEPENDS maccleaner_viz
        COMMENT "Staging MacCleanerViz-Swift.h")
    set_source_files_properties("${MACCLEANER_VIZ_HEADER_STAGED}" PROPERTIES GENERATED TRUE)

    add_executable(MacCleaner MACOSX_BUNDLE
        src/gui/main.mm
        src/gui/MCScanModel.mm
        src/gui/MCBigFilesModel.mm
        src/gui/MCProcessModel.mm
        src/gui/MCMainWindowController.mm
        src/gui/MCCleanerViewController.mm
        src/gui/MCLargeFilesViewController.mm
        src/gui/MCPerformanceViewController.mm
        src/gui/MCOptimizeSheetController.mm
        src/gui/MCUsageSummaryView.mm
        "${MACCLEANER_VIZ_HEADER_STAGED}"
    )
    target_link_libraries(MacCleaner PRIVATE maccleaner_core maccleaner_viz maccleaner_warnings)
    target_include_directories(MacCleaner PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/viz-header")

    # Linking a Swift static lib flips CMake's inferred linker language to
    # Swift, which then drives the link through swiftc *with the target's
    # compile flags* -- and swiftc rejects clang-only flags like -fobjc-arc.
    # Pin the link back to clang++; the Swift runtime resolves via the objects'
    # embedded auto-link entries (-lswiftCore et al.) given these search paths:
    # the SDK path for .tbd stubs at link time, /usr/lib/swift for the
    # OS-provided dylibs at run time.
    set_target_properties(MacCleaner PROPERTIES LINKER_LANGUAGE CXX)
    execute_process(COMMAND xcrun --show-sdk-path
        OUTPUT_VARIABLE MACCLEANER_SDK_PATH OUTPUT_STRIP_TRAILING_WHITESPACE)
    target_link_options(MacCleaner PRIVATE
        "-L${MACCLEANER_SDK_PATH}/usr/lib/swift"
        "-L/usr/lib/swift"
    )

    find_library(COCOA_FRAMEWORK Cocoa REQUIRED)
    # Quartz supplies QLPreviewView (the Large Files media preview);
    # UniformTypeIdentifiers supplies the UTType media gate in front of it.
    find_library(QUARTZ_FRAMEWORK Quartz REQUIRED)
    find_library(UTTYPE_FRAMEWORK UniformTypeIdentifiers REQUIRED)
    target_link_libraries(MacCleaner PRIVATE
        ${COCOA_FRAMEWORK} ${QUARTZ_FRAMEWORK} ${UTTYPE_FRAMEWORK})

    target_compile_options(MacCleaner PRIVATE -fobjc-arc)

    set_target_properties(MacCleaner PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
        MACOSX_BUNDLE_BUNDLE_NAME "MacCleaner"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.maccleaner.app"
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_COPYRIGHT "MIT"
    )
endif()

# --- tests ------------------------------------------------------------
if(MACCLEANER_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
