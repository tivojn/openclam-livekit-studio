if(NOT DEFINED OPENCLAM_NATIVE_BUILD_ROOT OR OPENCLAM_NATIVE_BUILD_ROOT STREQUAL "")
  message(FATAL_ERROR "OpenClam native build root is required for build-info sanitization")
endif()
if(NOT DEFINED OPENCLAM_CANONICAL_BUILD_ROOT OR OPENCLAM_CANONICAL_BUILD_ROOT STREQUAL "")
  message(FATAL_ERROR "OpenClam canonical build root is required for build-info sanitization")
endif()

set(_openclam_build_roots "${OPENCLAM_NATIVE_BUILD_ROOT}")
if(DEFINED OPENCLAM_NATIVE_BUILD_ROOT_ALIAS AND
   NOT "${OPENCLAM_NATIVE_BUILD_ROOT_ALIAS}" STREQUAL "" AND
   NOT "${OPENCLAM_NATIVE_BUILD_ROOT_ALIAS}" STREQUAL "${OPENCLAM_NATIVE_BUILD_ROOT}")
  list(APPEND _openclam_build_roots "${OPENCLAM_NATIVE_BUILD_ROOT_ALIAS}")
endif()

# OpenCV deliberately compiles its configuration report into cv2. Rewrite only
# that generated report, before version_string.inc is emitted and compiled.
# Compiler-generated __FILE__/debug paths are handled separately by Clang's
# prefix-map flags in stage-electron-opencv.sh.
foreach(_openclam_build_root IN LISTS _openclam_build_roots)
  string(REPLACE
    "${_openclam_build_root}"
    "${OPENCLAM_CANONICAL_BUILD_ROOT}"
    OPENCV_BUILD_INFO_STR
    "${OPENCV_BUILD_INFO_STR}"
  )
endforeach()

foreach(_openclam_forbidden_fragment
    "/var/folders/"
    "/private/var/folders/"
    "/TemporaryItems/"
    "openclam-opencv-build.")
  string(FIND "${OPENCV_BUILD_INFO_STR}" "${_openclam_forbidden_fragment}" _openclam_found)
  if(NOT _openclam_found EQUAL -1)
    message(FATAL_ERROR "OpenCV build information still contains a temporary build path")
  endif()
endforeach()

set(OPENCV_BUILD_INFO_STR "${OPENCV_BUILD_INFO_STR}" CACHE INTERNAL "" FORCE)
