# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

Optimize the Z80 backend of ravn/llvm-z80 (a GlobalISel-based LLVM fork) to match or beat SDCC code density. Test against RC700 PROM and BIOS sources in rc700-gensmedet.

Current: Clang 1771 bytes vs SDCC 1910 bytes (-7.3%) for the autoload PROM. BIOS: Clang 5861B vs SDCC 5797B (+64B, +1.1%). (IX/IY reverted to reserved — allocation was incomplete, #38.)

Session #12: 7 compiler fixes (#62-#68), 4 source fixes. BIOS 5952→5861B (-91B). Jump table threshold raised to 8 (-46B alone). G_UADDO/G_USUBO legal for i8.

Session #8: fixed #51 (BSS self-clobber), #52 (spill class). Merged memcpy_z80 — scroll() 20% faster (16xLDI), TYPE FILEX.PRN 4.7% faster end-to-end.

## Workspace Layout (`/Users/ravn/z80/`)

Everything lives under one folder:
- `llvm-z80/` — LLVM/clang fork with Z80 backend (shallow clone of github.com/ravn/llvm-z80)
- `rc700-gensmedet/` — RC700 CP/M system sources (github.com/ravn/rc700-gensmedet)
  - `autoload-in-c/` — Primary test case: ROA375 boot PROM in C (priority 1)
  - `rcbios-in-c/` — Secondary test case: CP/M BIOS in C (priority 2)
- `z88dk/` — z88dk toolchain (github.com/z88dk/z88dk, shallow clone). Contains sdcc/sccz80 compilers, Docker build workflows.

The autoload Makefile references `LLVM_Z80` relative to this workspace (via `$(CURDIR)/../../llvm-z80`).

## Build Commands

### LLVM-Z80 compiler (in Docker)
```bash
cd llvm-z80
cmake -C clang/cmake/caches/Z80.cmake -G Ninja -S llvm -B build
ninja -C build          # full build
ninja -C build clang    # just clang
ninja -C build llc      # just llc
```
Docker build image: `llvm-z80-build` (ubuntu:24.04 + cmake/ninja/clang/lld/python3).

### PROM builds (in rc700-gensmedet/autoload-in-c/)
```bash
make rom_parts          # SDCC build (needs z88dk in ../z88dk)
make clang              # Clang build (needs Docker + llvm-z80/build/)
make clang_asm          # Show clang assembly output
make mame               # Build SDCC PROM + boot test in MAME
make clang_prom         # Build clang PROM + install to MAME/RC700
```

### Tests
```bash
# LLVM lit tests
build/bin/llvm-lit llvm/test/CodeGen/Z80/

# Integration tests (in z80-utils/test-runner/)
cargo run                   # Default (O1, O2, Os)
cargo run -- clang          # Clang C suite
cargo run -- bench          # Code size benchmark
```

## Architecture

The llvm-z80 backend uses **GlobalISel** (not SelectionDAG). Key files:
- `llvm/lib/Target/Z80/Z80InstructionSelector.cpp` — instruction selection patterns (largest)
- `llvm/lib/Target/Z80/Z80LateOptimization.cpp` — peephole optimizations (most modified)
- `llvm/lib/Target/Z80/Z80ExpandPseudo.cpp` — post-RA pseudo expansion
- `llvm/lib/Target/Z80/Z80CallLowering.cpp` — sdcccall(0/1) calling conventions
- `llvm/lib/Target/Z80/Z80LegalizerInfo.cpp` — GlobalISel legalization
- `llvm/lib/Target/Z80/Z80RegisterBankInfo.cpp` — register bank selection

The PROM build uses `--target=z80 -Os` with `+static-stack` (BSS locals) and `+shadow-regs` (EXX for ISRs), linked with `ld.lld` via a custom linker script.

## Code Density Gap Analysis

Top root causes (clang vs SDCC):
1. **IX frame overhead** (~80B): PUSH IX + LD IX,addr + POP IX per function
2. **BSS pointer spills** (~100B): struct field pointers stored/reloaded from BSS instead of direct access
3. **8→16 bit promotion** (~50B): byte comparisons widened to 16-bit arithmetic
4. **IY prefix overhead** (~35B): FD-prefixed instructions
5. **Register pressure** (~80B): more conservative spilling than SDCC

Worst functions: `fdc_read_data` (+95B), `check_sysfile` (+59B), `lookup_sectors` (+54B).

## Key Z80 Optimization Patterns (from SDCC)

- **DJNZ** for `do { } while(--n)` loops (2 bytes vs 4)
- **LDIR/LDDR** for memcpy/memset
- **CP (HL)** for direct memory compare (1 byte, no temp)
- **BIT n,A** for single-bit tests (vs XOR/CP sequences)
- **ADD HL,HL** for 16-bit left shift (1 byte)
- **EX DE,HL** for register swap (1 byte, but destroys both)
- **SBC A,A** to materialize carry as 0x00/0xFF

## C Language Standard

Sources use **C23 features that work in both clang and z88dk zsdcc 4.5.0**.
When refactoring, prefer these over older C99/C11 equivalents.

Tested and working in both compilers:
- `true`, `false` as keywords (no stdbool.h needed)
- `nullptr`
- `_Bool`, `_Static_assert`
- `__typeof` / `typeof`
- `0b` binary literals
- designated initializers (`{.x = 42}`)
- for-loop declarations (`for (int i = 0; ...)`)
- `#embed`

**NOT working in zsdcc** (do not use in shared sources):
- `constexpr`
- `[[attributes]]` (use `__attribute__` instead)
- digit separators (`1'000` or `1_000`)
- `typeof` in expressions (`typeof(x){42}`)

## Environment

- Docker available for SDCC, **no brew** (never use or suggest brew)
- Native LLVM-Z80 clang at `llvm-z80/build-macos/bin/` (`make toolchain`)
- z88dk via Docker container (do not rebuild from source)
- CLion as IDE, command-line collaboration here
- MAME for hardware emulation testing
- Never create pull requests unless explicitly told to
- Always use `--no-ff` for git merges

## Workflow

- Record all user prompts in `tasks/prompts.md`
- Think out loud — show reasoning process
- All persistent notes stored in project (`tasks/`, `CLAUDE.md`), never in `~/.claude/`
- Plan in `tasks/todo.md`, lessons in `tasks/lessons.md`
- Never apologize. Be concise and accurate.
- Enter plan mode for non-trivial tasks. Re-plan if things go sideways.
- Verify changes work (tests, MAME boot) before marking done.

## Known Bugs in llvm-z80

- `address_space(2)` crashes Legalizer (port I/O uses inline asm workaround)
- `"hl"` inline asm constraint crashes IRTranslator
- hasFP=false has runtime bug (parked)
