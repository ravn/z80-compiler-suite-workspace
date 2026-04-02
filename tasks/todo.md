# Z80 Code Density Optimization Todo

## Status: IX/IY reverted to reserved — CLANG BEATS SDCC

SDCC: 1910B | Clang: 1853B | Clang is 57B smaller (-3.0%)

## Completed

- [x] Phase 1: Direct global+offset addressing (-234B, 2352→2118)
  - `LD A,(sym+off)` instead of `LD rr,addr; LD A,(rr)`
  - Cascading: fewer spills → IX removal fires more
  - All 40 lit tests pass, MAME boot PASS

- [x] Comparison narrowing: i16 icmp through zext/sext → i8 (-12B, 2118→2106)
  - LLVM InstCombine widens i8 compares to i16 via zext/sext
  - ISel now looks through extensions for EQ/NE/unsigned/signed predicates
  - Applied in both materialized G_ICMP and fused compare-and-branch
  - All 40 lit tests pass, MAME boot PASS

- [x] **hasFP=false regalloc bug** (-72B, 2106→2034, FIXED)
  - **Root cause:** IX constant propagation peephole in Z80LateOptimization
    treated INC IX inside a loop body as a one-time adjustment (+1) to the
    initial LD IX,0. Replaced `PUSH IX; POP HL` (actual counter) with
    `LD HL,1` (constant), creating an infinite loop in `fdc_write_full_cmd`.
  - **Bisection:** Automated binary search over 25 non-ISR functions found
    `fdc_write_full_cmd` as the sole culprit in 6 rounds.
  - **Fix:** Check for back-edges (loop membership) in the INC/DEC IX handler.
    If the block containing INC/DEC IX has a successor with number <= itself,
    mark IX as non-constant to prevent folding.
  - **Files changed:** Z80LateOptimization.cpp (loop check), Z80FrameLowering.cpp
    (removed staticStack guard)
  - **Test:** ix-loop-const-prop.ll, all 41 lit tests pass, MAME boot PASS

## Remaining (prioritized)

- [x] Loop index→pointer conversion (-76B, 2025→1949)
  - Root cause was **Z80IndexIV pass**, not SROA. The pass converted
    pointer-increment GEPs (`gep ptr, 1` → INC HL, 1B) into base+index
    GEPs (`gep base, index` → LD HL,base; ADD HL,BC, 4+B).
  - Fix: skip Z80IndexIV when +static-stack is active (locals in BSS,
    not IX-relative, so IX+d indexed addressing has no benefit).
  - TODO: investigate whether Z80IndexIV helps non-static-stack code
    where IX+d indexed addressing is available.
  - Files changed: Z80IndexIV.cpp (static-stack guard)
  - All 42 lit tests pass, MAME boot PASS

- [x] PUSH/POP instead of BSS spills across CALLs (-8B, 2033→2025)
  - Post-RA peephole: LD (bss),A; CALL; LD A,(bss) → PUSH AF; CALL; POP AF
  - Conservative: only single store/single load pairs (multi-load re-PUSH
    caused stack interaction bugs between nested converted functions)
  - 2 instances fired: fdc_write_full_cmd, main_relocated
  - Multi-load pattern (fdc_seek, fdc_select: 2+ loads) deferred — needs
    investigation of stack depth interaction when multiple callers/callees
    are converted simultaneously
  - GR16 variant (PUSH HL/DE/BC) also supported but no instances in PROM

- [x] ~~OR (HL) / AND (HL) fusion~~ — not worth it, only 3 SDCC instances,
  clang's direct addressing is equivalent. Closed #12.

- [x] MAME boot test to verify PROM correctness (2026-03-27, SW1711-I8.imd)

- [x] Interleaved C source in clang listing (make clang_src_lis)

- [ ] Investigate `clang -Weverything -c` on PROM sources
- [ ] Experiment with HI-Tech C to see how well it does

## Remaining (prioritized)

- [x] Signed 16-bit comparison bloat (ravn/llvm-z80#19) — FIXED: -38B
  - `icmp sgt i16 X, 0` (and SLE X, 0) now uses branchless algorithm:
    non-negative mask (RLCA; SBC A,A; CPL) AND non-zero test (OR hi,lo)
  - Fused branch: 12B (was 34B). Materialized: 14B (was 30B).
  - Avoids the JP PO/JP P MBB split entirely — no MBB splitting needed.
  - PROM: 1944B → 1906B (-38B). Now 6B SMALLER than SDCC (1912B).

- [x] Multi-value BSS spill across CALL (ravn/llvm-z80#20) — partial: -5B
  - Fixed LIFO safety bug: PUSH/POP depth tracking prevents stack corruption
    when multiple spills convert in the same MBB
  - Fixed dangling PUSH bug: flags check moved before store replacement
  - Enabled multi-load re-PUSH: POP+PUSH after each load except last
  - Fired: fdc_select_drive_cylinder_head (2 loads, 5B), fdc_seek (2 loads,
    5B but gc'd — function inlined), main_relocated (1 load, 4B, pre-existing)
  - Net new savings: 5B (1949→1944)
  - Remaining unconverted: cross-MBB spills (wait_fdc_ready, verify_seek_result),
    cross-register (fdc_get_result_bytes: store BC, load HL)

- [x] +static-stack incorrect code in large functions (ravn/llvm-z80#29) — FIXED
  - Root cause: SPILL_IMM8 expansion in static-stack BSS mode clobbered A register
    without saving it. The pseudo has no implicit-def of A (correct for IX-indexed
    LD (IX+d),n expansion), but the BSS path uses LD A,imm; LD (addr),A.
  - Fix: check isRegLiveAt(A) and PUSH AF/POP AF when A is live, matching SPILL_GR8.
  - File: Z80RegisterInfo.cpp (eliminateFrameIndex, static-stack SPILL_IMM8 handler)
  - Edge-case tests: 25/25 pass (was 14/25), all 43 lit tests pass
  - Also expanded test generator with 4 inline test categories (31 total)

- [x] Multi-compiler comparison framework (compiler-zoo)
  - Python + Makefile framework comparing clang vs z88dk zsdcc
  - Uses PROM flags: +static-stack, +shadow-regs, -disable-lsr (clang);
    --allow-unsafe-read, --sdcccall 1, --max-allocs-per-node 1M (zsdcc)
  - Fair size comparison: CRT excluded from both compilers
  - T-states measurement via z88dk-ticks
  - Assembly listings with debug info (clang: -g + objdump -S, zsdcc: --fverbose-asm)
  - 10 benchmark programs from existing test suite
  - Results: clang wins 7/10 on size, zsdcc wins on 32/64-bit arithmetic
  - Found 4 clang correctness failures in large benchmarks (ravn/llvm-z80#30)
  - 3 distinct bugs identified:
    - Bug A: static-stack volatile spill/reload mismatch (PUSH vs BSS load)
    - Bug B: 32-bit arithmetic codegen (CRC-32 produces wrong result, not static-stack specific)
    - Bug C: infinite loop in string ops without static-stack
  - 4 zsdcc correctness failures too (div/mod, string ops)
  - Renamed edgecase-testing → test-gen, added --categories flag (31 cat files)
  - --full flag for including _cat_*.c files in comparison
  - Portable NOINLINE macro for cross-compiler category files
  - Fixed compare.py: z88dk-ticks -trace now pipes through tail -20 (prevented disk fill)
  - Fixed compare.py: z88dk:v2.4 → z88dk:2.4 tag

- [ ] Investigate `clang -Weverything -c` on PROM sources
- [ ] Experiment with HI-Tech C to see how well it does
- [ ] Per-pair 16-bit copy cost in register allocator (ravn/llvm-z80#27)
- [ ] Tail call blocked by PUSH in IY copy (prom1_if_present: PUSH DE; POP IY;
  CALL __call_iy; RET — HasPush check falsely blocks, 1B)

- [x] Boot banner missing (ravn/llvm-z80#51) — **FIXED** (asm BSS clear)
  - Root cause: +static-stack BSS self-clobber in relocate_bios()
  - Compiler stored p+1 pointer to BSS, then *p=0 zeroed the low byte
  - memcpy destination became $EB00 instead of $EB69, zeroing .rodata
  - Fix: inline asm BSS clear (no compiler locals → no BSS overlap)
  - Sentinel word (0x1842) added to linker script to catch future bugs
  - Bisected to commit 1fa0b125 (#45 direct addressing changed codegen)

- [x] SPILL_GR16/RELOAD_GR16 reject Anyi16 class (ravn/llvm-z80#52) — **FIXED**
  - getLargestLegalSuperClass returned Anyi16 (includes SP), spill pseudos
    only accepted GR16. Fixed by widening pseudos + restricting superclass.
  - Lit test: spill-regclass.ll

- [ ] +static-stack allocates trivially-constant locals to BSS (ravn/llvm-z80#53)
  - All locals go to BSS regardless of register pressure
  - SDCC only spills when needed — smarter approach

- [ ] Large function codegen incorrect without +undocumented (ravn/llvm-z80#38)
  - Original trigger (IX/IY allocation) fixed by reserving IX/IY
  - Banner manifestation (#51) was actually BSS self-clobber, not regalloc
  - May still have residual issues in other large functions

## Issues filed (ravn/llvm-z80)
- ravn/llvm-z80#19 — Signed 16-bit comparison bloat — **CLOSED** (branchless SGT X,0)
- ravn/llvm-z80#20 — BSS spill across CALL (~33B remaining: 5 functions)
- ravn/llvm-z80#21 — Redundant 16-bit loads for port I/O — **CLOSED** (source fix + peephole)
- ravn/llvm-z80#22 — 8→16 bit promotion in byte comparisons — **CLOSED** (narrow add+cmp through zext, -19B)
- ravn/llvm-z80#23 — Null ISR shadow-reg overhead (~4B)
- ravn/llvm-z80#24 — Missed RRCA/RET C conditional return — **CLOSED** (-6B)
- ravn/llvm-z80#25 — fdc_seek inlining bloat (~21B)
- ravn/llvm-z80#26 — IX callee-save transfer wastes bytes vs PUSH/POP — **CLOSED** (-4B)
- ravn/llvm-z80#15 — Loop index→pointer conversion — FIXED (Z80IndexIV disabled)
- ravn/llvm-z80#16 — PUSH/POP instead of IX-indexed spills (~8B remaining, was ~40B pre-optimization)
- ravn/llvm-z80#12 — OR/AND (HL) memory operand fusion (~10B)
- ravn/llvm-z80#17 — hasFP=false regalloc bug — FIXED
- ravn/llvm-z80#18 — Known-value register copy optimization
- ravn/llvm-z80#7 — DJNZ, LDIR, CPIR, CP (HL) (~7B from DJNZ in PROM)
- ravn/llvm-z80#27 — Per-pair 16-bit register copy cost (structural)
- ravn/llvm-z80#28 — O0 code generation failures in large functions
- ravn/llvm-z80#29 — +static-stack incorrect code in large functions — **CLOSED** (SPILL_IMM8 missing A save)
- ravn/llvm-z80#30 — Incorrect code in benchmarks: umbrella for #31, #32, #33
- ravn/llvm-z80#31 — Static-stack volatile spill via PUSH, reload from stale BSS
- ravn/llvm-z80#32 — 32-bit CRC-32: PUSH/POP IX copies corrupt SP-relative offsets (root cause found, fix reverted)
- ravn/llvm-z80#34 — Crash: passing i32 as function argument
- ravn/llvm-z80#33 — bench_string infinite loop without +static-stack
- ravn/llvm-z80#37 — Undocumented LD A,IYH emitted without +undocumented — **CLOSED** (SEXT16/SEXT_GR8/ZEXT_GR8 expansion fix)
- ravn/llvm-z80#38 — Large function codegen incorrect without +undocumented (layout-sensitive)
- ravn/llvm-z80#39 — IX constant propagation removes setup when +undocumented sub-reg reads present — **CLOSED** (IXH/IXL use detection fix)
- ravn/llvm-z80#51 — Boot banner missing (BSS self-clobber) — **FIXED** (asm BSS clear in boot_entry.c)
- ravn/llvm-z80#52 — SPILL_GR16/RELOAD_GR16 reject Anyi16 — **FIXED** (widen pseudos + restrict superclass)
- ravn/llvm-z80#53 — +static-stack allocates trivially-constant locals to BSS

## Parked (investigated, not worth pursuing now)

- [x] BIT n,A branch fusion — investigated, AND+JR patterns already efficient
  (same size as BIT+JR). The `xor $80; cp $40` pattern is a range check,
  not a single-bit test. PostRACompareMerge correctly handles redundant OR A.

- [x] 8→16-bit comparison promotion — this IS happening but the root cause
  is the loop index→pointer problem (Phase 2), not type legalization.
  The comparisons themselves are i8, but the loop counter and pointer
  arithmetic are i16 because of index-based GEP.

- [x] Known-value register copy / duplicate LD rr,imm (ravn/llvm-z80#18)
  - 0 instances in current PROM (eliminated by hasFP=false + direct addressing)
  - Revisit when working on rcbios-in-c (priority 2 test case)

## Metrics

| Date | SDCC | Clang | Gap | Change |
|------|------|-------|-----|--------|
| 2026-03-26 | 1912 | 2352 | 440 (23%) | baseline (post-merge) |
| 2026-03-27 | 1912 | 2118 | 206 (11%) | Phase 1: direct addressing |
| 2026-03-27 | 1912 | 2106 | 194 (10%) | Narrow i16 cmp through zext/sext |
| 2026-03-27 | 1912 | 2034 | 122 (6%) | hasFP=false: IX constant prop loop fix |
| 2026-03-27 | 1912 | 2033 | 121 (6%) | OR A; LD r,0 → LD r,A peephole |
| 2026-03-27 | 1912 | 2025 | 113 (6%) | BSS spill → PUSH/POP across CALLs |
| 2026-03-27 | 1912 | 1949 | 37 (1.9%) | Disable Z80IndexIV for +static-stack |
| 2026-03-27 | 1912 | 1944 | 32 (1.7%) | Multi-load BSS spill→PUSH/POP + LIFO fix |
| 2026-03-28 | 1910 | 1906 | -6 (-0.3%) | Branchless SGT X,0 optimization (#19) |
| 2026-03-28 | 1910 | 1893 | -17 (-0.9%) | DMA macro fix + high-byte peephole (#21) |
| 2026-03-28 | 1910 | 1874 | -36 (-1.9%) | Narrow add+cmp through zext to 8-bit (#22) |
| 2026-03-28 | 1910 | 1870 | -40 (-2.1%) | IX callee-save transfer → PUSH/POP (#26) |
| 2026-03-28 | 1910 | 1864 | -46 (-2.4%) | Branch-to-RET + RRCA/RLCA peepholes (#24) |
| 2026-03-28 | 1910 | 1872 | -38 (-2.0%) | COPY16_PUSHPOP pseudo for IX/IY copies (#32) |
| 2026-03-31 | 1910 | 1876 | -34 (-1.8%) | +undocumented, IX sub-reg const-prop (#37/#39) |
| 2026-03-31 | 1910 | 1853 | -57 (-3.0%) | Revert IX/IY allocation (#38), reserve both |
| 2026-04-01 | 1910 | 1842 | -68 (-3.6%) | #45 const-addr LD, #46 ptrtoint fold, #47 linker wrap |
| 2026-04-02 | 1910 | 1842 | -68 (-3.6%) | Fix #51 BSS self-clobber, #52 spill class. BIOS 5709B |
| 2026-04-02 | 1910 | 1842 | -68 (-3.6%) | Merge memcpy_z80 scroll, BIOS 5742B. TYPE 4.7% faster |

## Todo: DMA-assisted screen scrolling

Investigate using Am9517A memory-to-memory DMA for CONOUT screen scroll instead of CPU LDIR/LDI.

- Screen scrolling (delete_line) is the #1 CPU consumer in CONOUT (12.4% of samples)
- Am9517A memory-to-memory uses ch0 (read/source) + ch1 (write/dest) together — hardwired, can't pick other pairs
- Current DMA channel assignments (from BIOS source): ch0=HD, ch1=floppy, ch3=CRT refresh, ch2=unclear
- Investigate if floppy DMA can be moved from ch1 to ch2 to free ch0+ch1 for memory-to-memory transfers
- DREQ line routing is a PCB question — check if FDC DREQ is wired to ch1 only or configurable

**Am9517A/8237 memory-to-memory transfer:**
- Command register bit 0 = 1: enable memory-to-memory mode
- Command register bit 1: channel 0 address hold (1 = fixed source address = block fill mode)
- Command register bit 3: compressed timing (1 = 2 clocks/cycle, 0 = 4 clocks/cycle)
- Ch0 current address = source, ch1 current address = destination
- Ch0 word count controls transfer length (terminates when count reaches 0)
- Transfer: read byte from ch0 address → internal temp register → write to ch1 address
- Software request on ch0 initiates the transfer (request register)
- Block fill: set bit 1, load ch0 with address of fill byte (held constant), ch1 with dest range
- Rate: up to 1.6 MB/s with compressed timing

**Documentation:**
- Am9517A (jbox.dk, scanned PDF): https://www.jbox.dk/rc702/hardware/intel-8237.pdf
- 8237 overview with register bits: https://8051-microcontrollers.blogspot.com/2015/08/direct-memory-access-and-dma-controlled_11.html
- Wikipedia: https://en.wikipedia.org/wiki/Intel_8237
- RC702 hardware reference: `RC702_HARDWARE_TECHNICAL_REFERENCE.md` in rc700-gensmedet

## Todo: z88dk

- Add +cpmdisk support for RC700 to z88dk
- Add semigraphics character rendering support for RC700 to z88dk

## Todo: CONOUT speed

- #50: Unroll LDIR into LDI chains for speed-critical memcpy (Duff's device pattern, 20% faster)
  - memcpy_z80() implemented and verified: inline C with {de}/{hl}/{bc} asm constraints
  - 16xLDI+JP PE loop, LDIR for remainder. All compile-time constants folded.
  - Benchmarked: 20% faster for >=16B (16T/byte vs 21T/byte LDIR)
  - BIOS scroll() converted: 5742B with memcpy_z80 (on experiment/duff-memcpy branch)
  - **No longer blocked**: was blocked by #51 BSS self-clobber, now fixed
  - Ready to merge when desired
- DMA-assisted scroll (see above)

## Todo: Clang vs SDCC size gap analysis (BIOS)

Clang 5746B vs SDCC 5577B (+169B, +3.0%). Investigate thoroughly:
- Generate side-by-side function size comparison (nm output)
- For each function where clang is larger, identify the root cause
- Map each gap to a specific compiler construction (register allocation,
  instruction selection, peephole, calling convention, etc.)
- File individual issues in ravn/llvm-z80 for each addressable gap
- Priority: largest gaps first (likely bios_conout_c, fdc_read_data)

## Todo: CLion debugger via MAME gdbstub

Set up CLion to debug the BIOS live via MAME's gdbstub:
- MAME launches with `-debug -debugger gdbstub -debugger_port 23946`
- CLion connects as a "Remote GDB Server" run configuration
- CLion uses clang/bios.elf (with -g debug info) as the symbol file
- Source view defaults to clang Z80 backend view of the shared sources
- Provide CMakeLists.txt or .run.xml configuration files in the project
- Simple instructions in README or CLANG_PORT.md: "click Run → Debug"
- Investigate: does GDB Z80 target exist? May need custom GDB or LLDB
- Investigate: MAME gdbstub protocol — does it support Z80 registers?
- Fallback: MAME's built-in debugger with `-debugscript` for breakpoints
