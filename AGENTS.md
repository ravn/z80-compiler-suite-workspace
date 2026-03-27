# AGENTS.md — AI Coding Agent Guide

This file helps AI agents (Claude, Copilot, etc.) work productively in the Z80 codebase. For project philosophy and self-improvement practices, see `AGENT.md`.

## Project Architecture at a Glance

Three interlinked Git repositories under `/Users/ravn/z80/`:

1. **`llvm-z80/`** — LLVM fork with Z80 backend (GlobalISel-based, ~50K lines in backend)
   - Optimization target: match SDCC code density on RC700 PROM (currently Clang 2106B vs SDCC 1912B)
   - Key files: `llvm/lib/Target/Z80/{Z80InstructionSelector.cpp, Z80LateOptimization.cpp, Z80CallLowering.cpp}`
   
2. **`rc700-gensmedet/`** — RC700 CP/M system in C and assembly
   - Primary test: `autoload-in-c/` (ROA375 boot PROM, 4KB ROM image)
   - Secondary test: `rcbios-in-c/` (CP/M BIOS source reconstruction)
   - Integration: MAME emulator for hardware-level boot validation
   
3. **`z88dk/`** — z88dk toolchain (SDCC compiler, sdasz80, appmake) via shallow clone
   - Used for building reference binaries and cross-compilation tests

## Critical Design: Z80 Instruction-Driven Code Generation

**The core philosophy differs from generic LLVM targets.** Z80 has special-purpose instructions that are dramatically cheaper than generic sequences:

- **DJNZ** (decrement B, jump if not zero) — 2 bytes for a loop decrement (vs 4+ bytes generic)
- **LDIR/LDDR** — memcpy in block mode; one instruction replaces a whole loop
- **CP (HL)** — compare A with memory at HL directly (1 byte, no temp register)
- **EX DE,HL** — swap register pairs atomically in 1 byte (but **destroys both registers**)
- **EXX** — swap BC/DE/HL shadow register pairs atomically (**critical: swaps all three at once**)
- **Carry bit tricks** — SBC A,A materializes carry as 0x00/0xFF; BIT n tests single bits

**When optimizing:** work backwards from these instructions to shape register allocation and instruction selection. Start with "what does this Z80 instruction need?" not "what generic code does this C produce?"

See `llvm-z80/CLAUDE.md` "Key Z80 Optimization Patterns" for expanded detail and concrete examples.

## Build Workflows

### LLVM-Z80 Compiler (Release build, ~5-10 min)

```bash
cd llvm-z80
cmake -C clang/cmake/caches/Z80.cmake -G Ninja -S llvm -B build
ninja -C build              # Full build (clang + llc + lld + Z80Runtime)
ninja -C build clang        # Just clang (faster)
ninja -C build llc          # Just llc (for IR→asm testing)
```

**Important**: The Z80.cmake cache enables ONLY Z80 target and clang project. After upstream merges, add `-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++` if GCC errors appear (newer LLVM uses clang-specific flags).

### PROM Builds (RC700 autoload image)

```bash
cd rc700-gensmedet/autoload-in-c

# SDCC reference build (requires z88dk:v2.4 Docker image)
make rom_parts

# Clang build (requires Docker + llvm-z80/build/)
make clang

# Show Clang assembly with annotations
make clang_asm

# Boot in MAME emulator (requires MAME + RC700 roms)
make mame

# Build PROM + install to MAME RC700 roms/
make clang_prom
```

See `autoload-in-c/Makefile` (lines 1-80) for Docker setup and build flags.

### Test Suites

**LLVM lit tests** (unit-level codegen):
```bash
cd llvm-z80/build/bin
./llvm-lit ../llvm/test/CodeGen/Z80/
./llvm-lit ../llvm/test/CodeGen/Z80/add.ll   # single test
```

**z80-utils integration tests** (realistic C code):
```bash
cd llvm-z80/z80-utils/test-runner
cargo run                    # Default suites (O1, O2, Os)
cargo run -- clang          # C test suite
cargo run -- bench          # Code size benchmark (Clang vs SDCC)
cargo run -- clang -opt Os  # Single opt level
```

Test cases: `z80-utils/test-runner/testcases/{clang,llc,sdcc}/`. Format: `/* expect: 0x00FF */` for expected return value.

## Key Project Conventions

### Code Density Gap Analysis

Current state (as of 2026-03-27):
- **SDCC**: 1912 bytes (reference)
- **Clang**: 2106 bytes (194 bytes gap = 10%)

Root causes (in priority order):

1. **hasFP=false runtime bug** (~82B blocked)
   — Disabling frame pointers breaks MAME boot (ISR issue). Verified via banner timestamp in binary.

2. **Index-based loops vs pointer increment** (~90B)
   — LLVM IR canonicalizes `*ptr++` to `GEP base, index` loops. Z80: `INC HL` (1B) vs `LD HL,base; ADD HL,BC` (7B+).
   — Affects: `compare_6bytes` (+42B), `check_sysfile` (+49B), `fdc_write_full_cmd` (+36B).

3. **IX frame overhead** (~80B, cascading)
   — Per function: PUSH IX + LD IX,addr + POP IX even for small locals. Eliminated in Phase 1 via direct addressing.

See `tasks/todo.md` for full prioritized list and metrics.

### PROM Binary Verification

**Always verify PROM freshness via build timestamp before claiming MAME test results.**

The autoload PROM includes a `build_stamp.h` macro with compile timestamp (e.g., `"ROA375 2026-03-27 08.37/ravn"`). Check this in the banner message before concluding a test result is valid. Stale binaries (rebuilt without timestamp update) cause false conclusions.

### Calling Conventions

Two supported SDCC calling conventions:

- **`__sdcccall(0)`** — Register-clobbered (caller saves registers A, B, C, D, E)
  - Used in: compiler-rt builtins, cross-compilation with SDCC

- **`__sdcccall(1)`** — Register-preserved (callee saves B, C, D, E)
  - Used in: PROM code, most production applications
  - PROM build flags: `-Cs"--sdcccall 1" -Cs"--allow-unsafe-read" -Cs"--codeseg BOOT"`

See `llvm-z80/CLAUDE.md` "Architecture" section for detailed differences.

## Integration Points

### ELF ↔ SDCC Cross-Linking

Tools in `z80-utils/`:
- `elf2rel` — convert Clang ELF `.a` archive to SDCC `.lib` format (enable linking SDCC code with Clang)
- `rel2elf` — reverse (link Clang with SDCC .rel object files)

Used for compatibility testing and gradual migration strategies.

### MAME RC700 Emulator Integration

PROM build targets `$(MAME)/roms/rc702/roa375.ic66` by default. Makefile supports:
- `make mame` — build, install, launch MAME debugger
- `make rc700` — build, compile RC700 emulator, run bootstrap test

Lua scripts for debugging: `mame_boot_test.lua`, `mame_trace_fdc.lua`, etc.

### Docker Build Isolation

Build image: `z88dk:v2.4` (Ubuntu 24.04 + z88dk + SDCC + appmake).

```bash
# Run z88dk builds in container (auto-mounted `/src`)
docker run --rm -v $(pwd):/src -w /src z88dk:v2.4 zcc ... 
```

**Constraint**: No `brew` available in CI (never suggest or use). All external tools available via Docker or Git clone.

## Data Flow Patterns

### PROM Build Pipeline

```
C source (rom.c, boot_rom.c, intvec.c)
    ↓
zcc (z88dk SDCC)
    ↓
Assembled code (prom0_BOOT.bin, prom0_CODE.bin)
    ↓
sections.asm (linker directive: BOOT at 0x0000, CODE at 0x7000 in RAM)
    ↓
prom0.bin → appmake (pad to 4096, convert to IC66 format)
    ↓
prom0.ic66 (PROM image, installed to MAME roms/rc702/)
```

**Memory layout** (PROM at 0x0000, CODE copied to RAM at 0x7000 by boot):
- 0x0000–0x0065: BOOT section (entry point, NMI stub)
- 0x0068–0x0FFF: CODE section (IVT, HAL, FDC driver, boot logic)

### Z80 Backend: GlobalISel Pipeline

```
LLVM IR (from Clang/LLVMIRGen)
    ↓ [Z80LegalizerInfo]
    ├─ Widen small ints, legalize operations → G_* MIR nodes
    ↓
    ├─ [Z80RegisterBankInfo]
    ├─ Assign register banks (GPR, flags)
    ↓
    ├─ [Z80InstructionSelector]
    ├─ Pattern matching: G_LOAD → LD, G_ADD → ADD (tablegen-driven)
    ├─ Fused patterns: G_ICMP + G_BRCOND → CP + JR
    ├─ Special Z80 patterns: G_OR(reg, G_LOAD) → OR (HL)
    ↓
    ├─ [Passes: Z80LateOptimization, Z80PostRACompareMerge, etc.]
    ├─ Peephole optimizations (post-RA)
    ↓
MachineCode
    ↓ [AsmPrinter, Emitter]
    ↓
Object file (.o) or assembly (.s)
```

Key files:
- **Z80InstructionSelector.cpp** (~2500 lines) — pattern-matching rules (largest backend file)
- **Z80LateOptimization.cpp** (~800 lines) — peephole optimizations (most frequently modified)
- **Z80InstrGISel.td** — GlobalISel patterns (tablegen-driven)
- **Z80CallLowering.cpp** — calling convention lowering (handles SDCC calling conventions)

## Common Workflows for AI Agents

### Investigating Code Density Regressions

1. **Capture baseline**: `make clang_asm > baseline.lis` before changes
2. **Run test**: apply optimization, rebuild, `make clang_asm > new.lis`
3. **Diff analysis**: `diff baseline.lis new.lis | head -50` to find affected functions
4. **MAME validation**: `make clang_prom && make mame` — boot must complete banner
5. **Verify binary**: Check build timestamp in banner matches current time

### Adding Optimization Patterns

For new Z80 instruction patterns (e.g., CP (HL), OR (HL)):

1. Add `G_*` pattern to `Z80InstrGISel.td` (tablegen) or `Z80InstructionSelector.cpp` (C++)
2. Run lit tests: `llvm-lit llvm/test/CodeGen/Z80/`
3. Run integration suite: `cargo run -- clang -opt Os`
4. Measure PROM size: `make clang_prom && wc -c prom0.ic66`

### Tracing Register Allocation Issues

Use `-machine-pass-after=<pass-name>` to dump MIR before/after passes:

```bash
clang -c rom.c -O2 --target=z80 \
    -mllvm -print-before=regalloc -mllvm -print-after=regalloc
```

Then inspect `*.mir` files in build directory.

## External Resources

- **Z80 Instruction Set**: `llvm-z80/Z80_INSTRUCTION_SET.md`
- **RC700 Hardware Ref**: `rc700-gensmedet/RC702_HARDWARE_TECHNICAL_REFERENCE.md`
- **LLVM GlobalISel Guide**: https://llvm.org/docs/GlobalISel/
- **z88dk/SDCC Docs**: https://www.z88dk.org/wiki/doku.php

## Known Limitations

- `address_space(2)` (port I/O) crashes Legalizer → use inline asm workaround
- `"hl"` inline asm constraint crashes IRTranslator → use `"r"` + manual MOV
- SM83 (Game Boy Z80 variant) partially supported, untested on hardware
- C++ support experimental, untested
- Code generation NOT production-ready (use SDCC for production)

---

**Last updated**: 2026-03-27  
**Workspace**: `/Users/ravn/z80/`  
**Key contact files**: `CLAUDE.md` (architecture), `tasks/lessons.md` (patterns), `tasks/todo.md` (roadmap)

