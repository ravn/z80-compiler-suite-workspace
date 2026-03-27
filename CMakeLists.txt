cmake_minimum_required(VERSION 3.20)
project(z80-workspace C CXX)

# Top-level CMakeLists.txt for CLion — indexing and navigation only.
# Actual builds use Makefiles (autoload/bios) or ninja (llvm-z80).

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# z88dk headers for the RC700 subprojects
set(Z88DK_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/rc700-gensmedet/z88dk/include)

# --- z88dk Docker workflow files (for reference/editing) ---
add_custom_target(z88dk_docker_files SOURCES
    z88dk/z88dk.Dockerfile
    z88dk/.github/workflows/build-docker.yml
    z88dk/.github/workflows/build-docker-tag.yml
    z88dk/.github/workflows/build-docker-weekly.yml
)

# --- RC700 autoload PROM (C, z88dk/sdcc + clang) ---
add_subdirectory(rc700-gensmedet/autoload-in-c)

# --- RC700 BIOS (C, z88dk/sdcc) ---
add_subdirectory(rc700-gensmedet/rcbios-in-c)

# --- LLVM Z80 backend (C++, for navigation only) ---
# Not add_subdirectory(llvm-z80) — that would configure all of LLVM.
# Instead, index just the Z80 backend sources for code navigation.

set(LLVM_Z80_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/llvm-z80)

file(GLOB Z80_BACKEND_CPP  ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/*.cpp)
file(GLOB Z80_BACKEND_H    ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/*.h)
file(GLOB Z80_BACKEND_TD   ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/*.td)
file(GLOB Z80_MC_CPP       ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/MCTargetDesc/*.cpp)
file(GLOB Z80_MC_H         ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/MCTargetDesc/*.h)
file(GLOB Z80_ASMPARSER    ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/AsmParser/*.cpp)
file(GLOB Z80_DISASM       ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80/Disassembler/*.cpp)

add_library(z80_backend_index OBJECT EXCLUDE_FROM_ALL
    ${Z80_BACKEND_CPP}
    ${Z80_BACKEND_H}
    ${Z80_MC_CPP}
    ${Z80_MC_H}
    ${Z80_ASMPARSER}
    ${Z80_DISASM}
    # Clang Z80 target
    ${LLVM_Z80_ROOT}/clang/lib/Basic/Targets/Z80.cpp
    ${LLVM_Z80_ROOT}/clang/lib/Basic/Targets/Z80.h
)

# TableGen files shown in project tree but not compiled
add_custom_target(z80_tablegen_files SOURCES ${Z80_BACKEND_TD})

target_include_directories(z80_backend_index PRIVATE
    # LLVM source headers
    ${LLVM_Z80_ROOT}/llvm/include
    ${LLVM_Z80_ROOT}/clang/include
    # Generated headers (TableGen output, config)
    ${LLVM_Z80_ROOT}/build/include
    ${LLVM_Z80_ROOT}/build/lib/Target/Z80
    ${LLVM_Z80_ROOT}/build/tools/clang/include
    # Target-specific headers
    ${LLVM_Z80_ROOT}/llvm/lib/Target/Z80
)

target_compile_features(z80_backend_index PRIVATE cxx_std_17)

# Custom targets for real builds (invoked from CLion run configurations)
add_custom_target(llvm-z80-build
    COMMAND ninja -C ${LLVM_Z80_ROOT}/build clang llc ld.lld
    WORKING_DIRECTORY ${LLVM_Z80_ROOT}
    COMMENT "Building llvm-z80 (clang + llc + lld)"
)

add_custom_target(llvm-z80-test
    COMMAND ${LLVM_Z80_ROOT}/build/bin/llvm-lit ${LLVM_Z80_ROOT}/llvm/test/CodeGen/Z80/
    WORKING_DIRECTORY ${LLVM_Z80_ROOT}
    COMMENT "Running Z80 lit tests"
)

add_custom_target(prom-sdcc
    COMMAND make rom_parts
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/rc700-gensmedet/autoload-in-c
    COMMENT "Building PROM with SDCC"
)

add_custom_target(prom-clang
    COMMAND make clang
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/rc700-gensmedet/autoload-in-c
    COMMENT "Building PROM with Clang"
)

add_custom_target(prom-clang-asm
    COMMAND make clang_asm
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/rc700-gensmedet/autoload-in-c
    COMMENT "Show Clang Z80 assembly output"
)
