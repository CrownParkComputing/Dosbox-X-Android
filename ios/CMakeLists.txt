# The iOS application.
#
#   ios/build-core.sh                      # produces the static libraries
#   cmake -S ios -B ios/build/app -G Xcode \
#         -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64
#   cmake --build ios/build/app --config Release
#
# CMake generates the Xcode project rather than one being committed: a
# .pbxproj is 40 KB of generated state that nobody can review in a diff, and
# every setting worth having is expressed here instead.
cmake_minimum_required(VERSION 3.20)
project(RetroDos LANGUAGES CXX)

set(RETRODOS_VERSION "1.0.0" CACHE STRING "CFBundleShortVersionString")
# App Store Connect refuses a CFBundleVersion it has already seen, and says so
# only after the whole upload has transferred, so CI stamps a UTC timestamp.
set(RETRODOS_BUILD "1" CACHE STRING "CFBundleVersion")
set(RETRODOS_BUNDLE_ID "com.crownparkcomputing.dosboxretro" CACHE STRING "bundle id")
set(RETRODOS_DISPLAY_NAME "Retro-DOS" CACHE STRING "CFBundleDisplayName")
set(RETRODOS_TEAM_ID "88A3T9K9C5" CACHE STRING "DEVELOPMENT_TEAM")

if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0")
endif()

set(PLATFORM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build/$<IF:$<CONFIG:Debug>,iphoneos,iphoneos>/out")
set(LIBDIR "${CMAKE_CURRENT_SOURCE_DIR}/build/iphoneos/out")
foreach(lib libretrodos.a libSDL3.a)
  if(NOT EXISTS "${LIBDIR}/${lib}")
    message(FATAL_ERROR "${LIBDIR}/${lib} is missing -- run ios/build-core.sh first.")
  endif()
endforeach()

# The demo content the frontend looks for as demo/DEMO.COM and
# demo/FREEDOS.IMG, relative to the bundle. It lives under android/ because
# that is where it was first packaged; it is read here, never modified.
set(DEMO_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../android/app/src/main/assets/demo")
set(DEMO_FILES "${DEMO_SRC}/DEMO.COM" "${DEMO_SRC}/FREEDOS.IMG")
foreach(f ${DEMO_FILES})
  if(NOT EXISTS "${f}")
    message(FATAL_ERROR "bundled demo content missing: ${f}")
  endif()
endforeach()

configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

# One translation unit, deliberately empty. Everything executable is already
# inside libretrodos.a, including the frontend's main(); Xcode still wants a
# source file to hang the target on.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/app_main.cpp"
     "// Intentionally empty: main() comes from libretrodos.a (the frontend),\n"
     "// which SDL renames to SDL_main and calls from its own UIKit entry.\n")

add_executable(RetroDos MACOSX_BUNDLE
  "${CMAKE_CURRENT_BINARY_DIR}/app_main.cpp"
  ${DEMO_FILES})

set_source_files_properties(${DEMO_FILES} PROPERTIES
  MACOSX_PACKAGE_LOCATION "Resources/demo")

set_target_properties(RetroDos PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${RETRODOS_BUNDLE_ID}"
  XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${RETRODOS_TEAM_ID}"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"          # iPhone and iPad
  XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")

# -all_load, and it is not optional: nothing in the empty main references the
# emulator, so without it the linker discards essentially all of it and the app
# starts into a black screen with no error.
target_link_options(RetroDos PRIVATE
  "-Wl,-all_load" "${LIBDIR}/libretrodos.a")

target_link_libraries(RetroDos PRIVATE
  "${LIBDIR}/libSDL3.a" z iconv
  "-framework CoreFoundation" "-framework CoreMIDI" "-framework AudioToolbox"
  "-framework UIKit" "-framework Foundation" "-framework CoreGraphics"
  "-framework CoreVideo" "-framework CoreMedia" "-framework AVFoundation"
  "-framework CoreBluetooth" "-framework CoreMotion" "-framework Metal"
  "-framework QuartzCore" "-framework OpenGLES"
  "-framework UniformTypeIdentifiers" "-framework ImageIO"
  "-weak_framework GameController" "-weak_framework CoreHaptics")
