CMAKE_MINIMUM_REQUIRED(VERSION 3.17)
SET(CMAKE_CXX_STANDARD 17)
SET(CMAKE_COLOR_DIAGNOSTICS ON)
SET(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# gnd_sfx - the playback engine of the addon as a GDExtension. Built like libreloaded (Rails
# Reloaded), which links this addon into its game: godot-cpp's CMake, GODOTCPP_PRECISION single
# for a stock Godot and double for Rails Reloaded's, the Linux release in ci/docker/linux-sdk for
# an old glibc (see Makefile)
FIND_PACKAGE(Python3 3.4 REQUIRED)
ADD_SUBDIRECTORY(vendor/godot-cpp SYSTEM)
SET(CMAKE_MODULE_PATH "${CMAKE_MODULE_PATH};${godot-cpp_SOURCE_DIR}/cmake")
INCLUDE(GodotCPPModule)
GET_TARGET_PROPERTY(GODOTCPP_SUFFIX godot::cpp GODOTCPP_SUFFIX)
GET_TARGET_PROPERTY(GODOTCPP_PLATFORM godot::cpp GODOTCPP_PLATFORM)

PROJECT(gndsfx LANGUAGES CXX)

FILE(GLOB SRC_FILES CONFIGURE_DEPENDS "src/*.cpp" "src/*.hpp")
ADD_LIBRARY(gndsfx SHARED ${SRC_FILES})
TARGET_LINK_LIBRARIES(gndsfx PRIVATE godot::cpp)
IF (NOT MSVC)
    TARGET_COMPILE_OPTIONS(gndsfx PRIVATE -Wall -Wextra -Wno-unused-parameter)
ENDIF ()

# The class reference shown by the editor's help - compiled in where the editor loads the library
FILE(GLOB DOC_XML CONFIGURE_DEPENDS "doc_classes/*.xml")
IF (DOC_XML AND NOT GODOTCPP_TARGET STREQUAL "template_release")
    TARGET_DOC_SOURCES(gndsfx "${DOC_XML}")
ENDIF ()

# A MinGW DLL would otherwise need libstdc++/libgcc/libwinpthread next to the game (use_static_cpp)
IF (MINGW)
    TARGET_LINK_OPTIONS(gndsfx PRIVATE -static-libgcc -static-libstdc++ -static)
ENDIF ()

SET(GND_SFX_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/addons/gnd_sfx/bin/${GODOTCPP_PLATFORM}")
SET_TARGET_PROPERTIES(gndsfx PROPERTIES
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
        PREFIX "lib"
        OUTPUT_NAME "gndsfx${GODOTCPP_SUFFIX}"
        LIBRARY_OUTPUT_DIRECTORY "${GND_SFX_BIN_DIR}"
        RUNTIME_OUTPUT_DIRECTORY "${GND_SFX_BIN_DIR}"
)
