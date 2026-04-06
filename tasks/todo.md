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
- [x] ~~Experiment with HI-Tech C~~ — parked, not pursuing

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

- [x] Build llvm-z80 clang natively on macOS (eliminate Docker for compilation)
- [ ] Get CLion remote development working for this project
- [x] Recalibrate DELAY_T for -Oz (or make delay() timing-independent) — DONE: delay_ms() macro + DELAY_T=16
- [ ] Build z88dk locally on macOS (eliminate Docker for SDCC builds)
- [ ] Simplify BIOS jump table IFDEF logic (REL14/REL20/HARDDISK conditional JP entries)
- [ ] Clang PROM missing NMI handler (RETN) at 0x0066 — SDCC has it in boot_rom.c
- [x] PROM delay() should take milliseconds — DONE: delay_ms(), z80_delay_ms() for SDCC
- [ ] Investigate how much code can be shared between autoload PROM and BIOS
- [ ] Investigate clang-only features (C17/C23, attributes) that could improve Z80 codegen
- [ ] Investigate if compare_6bytes could use CPI for more compact codegen
- [ ] Legacy boot reads to INTVEC_ADDR (0x7000) — assumes exactly 0x7000 bytes from disk. May be a latent bug if disk content differs
- [ ] Investigate `clang -Weverything -c` on PROM sources
- [x] ~~Experiment with HI-Tech C~~ — parked, not pursuing
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
- ravn/llvm-z80#54 — Fall-through JP elimination (6B)
- ravn/llvm-z80#55 — ADD HL,DE commutativity peephole — **CLOSED** (-6B)
- ravn/llvm-z80#56 — Shift-left-7 strength reduction — **CLOSED** (RRCA+AND, -4B)
- ravn/llvm-z80#57 — Comparison reversal: LD D,A; LD A,imm; CP D → CP imm (3B)
- ravn/llvm-z80#58 — JP where JR suffices / branch relaxation (3B)
- ravn/llvm-z80#59 — 16-bit loop counter where 8-bit suffices — **FIXED** (-2B, comparison only)
- ravn/llvm-z80#60 — Redundant LD A,reg when A unchanged (4B)
- ravn/llvm-z80#61 — Missing DEC (HL) / INC (HL) for in-memory ops (4B)

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
| 2026-04-02 | 1910 | 1842 | -68 (-3.6%) | CLion integration: __z80__ guards, MAME run configs |
| 2026-04-03 | 1910 | 1802 | -108 (-5.7%) | Native macOS build, delay_ms(), -Oz, dead code GC |
| 2026-04-03 | 1910 | 1791 | -119 (-6.2%) | Static inlining: fdc_seek, display_banner_and_start_crt |
| 2026-04-06 | 1910 | 1791 | -119 (-6.2%) | Gap analysis: 8 new issues (#54-#61), ~37B potential |
| 2026-04-06 | 1910 | 1789 | -121 (-6.3%) | Fix #59: narrow 16-bit loop compare to 8-bit CP (-2B) |
| 2026-04-06 | 1910 | 1785 | -125 (-6.5%) | Fix #56: SHL 7 via RRCA+AND (-4B) |
| 2026-04-06 | 1910 | 1779 | -131 (-6.9%) | Fix #55: ADD HL,DE commutativity (-6B) |

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

- [x] #50: memcpy_z80 — 16xLDI Duff's device for scroll() (MERGED)
  - 20% faster per-byte (16T vs 21T), 4.7% end-to-end on TYPE FILEX.PRN
  - Cycle test: 170.9M → 162.8M cycles

- Hardware scroll via split-DMA (from ROA375 PROM analysis):
  The original asm PROM uses **zero-copy hardware scrolling**:
  - Display buffer at DSPSTR (0xF800) treated as circular buffer
  - SCROLLOFSET variable tracks where visible screen starts
  - Ch2 (high priority): DMA from DSPSTR+S to end (2000-S bytes)
  - Ch3 (low priority): DMA from DSPSTR for wrap-around (S bytes)
  - 8275 CRT requests 2000 chars/frame; ch2 serves tail, ch3 serves head
  - Scroll = update SCROLLOFSET (one word write) — no memory copy at all
  - Requires ch2 number < ch3 number (Am9517A priority: lower ch = higher)
  - The C BIOS currently copies 1920 bytes per scroll (memcpy_z80)
  - Implementing this in C would eliminate scroll CPU cost entirely
  - Complications: insert_line/delete_line need to modify the circular
    buffer correctly; clear_screen resets offset to 0; cursor addressing
    must account for the offset
  - DMA channel assignments are now configurable (feature/dma-channel-config)

- DMA-assisted memory-to-memory scroll (alternative approach):
  - Am9517A memory-to-memory mode: ch0 (source) + ch1 (dest), software request
  - No DREQ lines needed — triggered by writing to request register (port 0xF9)
  - Would still copy memory but via DMA instead of CPU (frees CPU during copy)
  - Requires ch0+ch1 free during scroll (no concurrent disk I/O — safe in CONOUT)
  - Less benefit than hardware scroll but simpler to implement

## Todo: Clang vs SDCC size gap analysis (BIOS)

Clang 5746B vs SDCC 5577B (+169B, +3.0%). Investigate thoroughly:
- Generate side-by-side function size comparison (nm output)
- For each function where clang is larger, identify the root cause
- Map each gap to a specific compiler construction (register allocation,
  instruction selection, peephole, calling convention, etc.)
- File individual issues in ravn/llvm-z80 for each addressable gap
- Priority: largest gaps first (likely bios_conout_c, fdc_read_data)

## Todo: CLion debugger via MAME gdbstub

**Done (session #9):**
- [x] CLion fully indexes BIOS via `__z80__` guards (HOST_TEST removed)
- [x] .clangd: `-xc -std=c99 -Iclang -DMSIZE=56` + warning suppressions
- [x] 6 persistent run configurations in .idea/runConfigurations/
- [x] MAME GDB Stub run config (`run_mame.sh -g`)
- [x] Port I/O stubs use volatile (CLion doesn't assume constant zero)
- [x] bios_sources EXCLUDE_FROM_ALL (Build All doesn't try host compile)

**Remaining:**
- [ ] Build z80-elf-gdb from binutils-gdb for source-level debugging
  - `./configure --target=z80-unknown-elf` + `make all-gdb`
  - CLion Remote GDB Server: z80-elf-gdb + bios.elf + localhost:23946
- [ ] Fallback: enhance gdb_trace.py with pyelftools DWARF source mapping

## Todo: MAME DMA port assignment from emulated code

Currently MAME's RC702 driver hardcodes the DMA channel-to-device wiring
(which DREQ/DACK lines connect to which peripheral). Investigate whether
the emulated Z80 code can configure this dynamically instead:
- Can the Am9517A DMA mode register writes in MAME's 8237 emulation be
  observed to infer which channel is used for what?
- Does MAME's rc702.cpp wire DREQ/DACK lines at machine config time?
  If so, can this be made software-configurable?
- The RC702 hardware has fixed PCB traces for DREQ routing — the software
  can't change which peripheral triggers which DMA channel. But MAME
  emulation doesn't need to follow this constraint.
- Goal: allow the BIOS C code to use different channel assignments without
  also modifying the MAME driver source.

## Todo: MAME DMA port assignment from emulated code

Currently MAME's RC702 driver hardcodes the DMA channel-to-device wiring
(which DREQ/DACK lines connect to which peripheral). Investigate whether
the emulated Z80 code can configure this dynamically instead:
- Can the Am9517A DMA mode register writes in MAME's 8237 emulation be
  observed to infer which channel is used for what?
- Does MAME's rc702.cpp wire DREQ/DACK lines at machine config time?
  If so, can this be made software-configurable?
- The RC702 hardware has fixed PCB traces for DREQ routing — the software
  can't change which peripheral triggers which DMA channel. But MAME
  emulation doesn't need to follow this constraint.
- Goal: allow the BIOS C code to use different channel assignments without
  also modifying the MAME driver source.

## Todo: Sync MAME port map with BIOS port definitions

The MAME RC702 driver (`rc702.cpp`) hardcodes I/O port addresses in its
`io_map()` function (e.g. CRT at 0x00, FDC at 0x04, DMA at 0xF0). These
must match the `PORT_*` constants in `hal.h`. Currently they're maintained
independently — changing a port in one place requires manually updating
the other.

Investigate:
- Can MAME's rc702.cpp read port assignments from a shared header or
  generated file that's also used by the BIOS build?
- Or: generate the MAME io_map() fragment from hal.h at build time
  (e.g. a Python script that parses #define PORT_* and emits C++ map calls)
- Or: have the MAME driver read port assignments from the PROM binary
  itself (a configuration table embedded in the ROM)
- Note: DMA channel assignments (DMA_CH_*) affect which DREQ/DACK lines
  connect to which peripheral in MAME — this is separate from port addresses
  but also needs to stay in sync

## Todo: 26th status line via DMA split

Investigate using the ch2/ch3 DMA split to display a 26th status line
sourced from a separate memory region, without the 8275's 25-row limit:

- The 8275 CRT controller can be programmed for 26 rows instead of 25
- The DMA split (ch2 tail, ch3 head) could point ch3 at a status buffer
  located outside the 2000-byte display area at 0xF800
- The status line buffer must NOT overlap with the work area (0xFFD0+)
  or BSS variables
- Possible location: below display memory (e.g. 0xF750, 80 bytes)
  or in a gap between BIOS BSS end and the display buffer
- Content: drive letter, user number, current track, free space, etc.
- The circular scroll approach already uses the ch2/ch3 split — the
  status line would be a third segment. Check if this is feasible
  with only two DMA channels, or if the status line replaces the
  wrap-around (meaning the scroll buffer shrinks to 1920 bytes +
  80-byte status line = 2000 bytes, no wrap needed)
- Alternative: use the 8275's built-in "end of screen" row with a
  fixed DMA source address (simpler but may require 8275-specific setup)

## Todo: Circular display buffer via DMA split (zero-copy scroll)

The ROA375 PROM already does this — investigate implementing it in the C BIOS:

- Display buffer at DSPSTR (0xF800) is a 2000-byte circular buffer
- SCROLLOFSET tracks where the visible screen starts (0..1999)
- Ch2 (high priority): DMA from DSPSTR+S to end of buffer (2000-S bytes)
- Ch3 (low priority): DMA from DSPSTR for wrap-around (S bytes)
- Scroll up = add 80 to SCROLLOFSET (mod 2000) — no memory copy
- The isr_crt() already reprograms ch2/ch3 every frame at 50Hz
- Just needs to compute the split addresses from SCROLLOFSET

Impact on CONOUT:
- scroll(): set SCROLLOFSET += 80, memset new bottom row — no memcpy
- displ(): screen[locad] must account for circular offset
- insert_line/delete_line: need to work within circular buffer
- clear_screen(): reset SCROLLOFSET = 0, memset entire buffer
- cursor addressing: locad = (cury + curx + SCROLLOFSET) % 2000

Prerequisite: remove BGSTAR (background semigraphics overlay) support.
BGSTAR maintains a parallel 250-byte bitmap that shadows display memory
and must be scrolled in sync. With a circular buffer, keeping BGSTAR
in sync adds complexity for no practical benefit — BGSTAR is an RC702
demo feature, not used by any CP/M application.

Estimated speedup: eliminates 1920-byte copy entirely (currently 31950T
with memcpy_z80, would become ~100T for offset update + 80-byte memset).
That's ~99.7% reduction in scroll CPU cost.

## Todo: Build variants — compatible and fast

Two BIOS variants from the same source, each in its own output directory:

- `clang/` — compatible: all features (BGSTAR, memcpy scroll), drop-in
  replacement for original BIOS, 100% feature parity
- `clang-fast/` — optimized: circular DMA scroll, no BGSTAR, tuned for
  interactive terminal use (editing, compiling, TYPE)
- Same for SDCC: `sdcc/` and `sdcc-fast/`

Implementation:
- `VARIANT ?= compatible` (default) in Makefile
- `make bios` → `clang/bios.cim` (compatible)
- `make bios VARIANT=fast` → `clang-fast/bios.cim`
- Fast variant adds `-DFAST_SCROLL` to CFLAGS
- Source uses `#ifdef FAST_SCROLL` to select circular buffer vs memcpy
- Each variant directory has its own sub-Makefile (or shared with extra flags)
- MAME targets respect VARIANT: `make mame-maxi VARIANT=fast`

## Reference: z88dk-dis

Linear Z80 disassembler in z88dk Docker image. Reads `.map` files for symbol labels.
Usage: `z88dk-dis -mz80 -o 0x0000 -x sdcc/bios.map sdcc/bios.cim`
Limitation: no data/code distinction — disassembles everything as instructions.
The SDCC `.lis` files and `llvm-objdump -d` for clang are better for routine analysis.
Useful for quick spot-checks of specific address ranges in raw `.cim` binaries.

## Reference: Getting T-states from compiler output

### SDCC (via z88dk)
Add `-Cs"--fverbose-asm"` to ZFLAGS. This makes sdcc annotate each
instruction with its T-state count in the `.c.asm` intermediate file.
The `.c.asm` files are generated during compilation but may be cleaned
by z88dk. To preserve them, add `--list` to the final link step or
compile with `-S` to get assembly only.

Example: `zcc ... -Cs"--fverbose-asm" -S bios.c -o bios.c.asm`

### Clang (LLVM-Z80)
The clang Z80 backend does not emit T-state annotations.
Use the Z80 instruction timing table:
- LD r,r: 4T | LD r,n: 7T | LD r,(HL): 7T | LD (HL),r: 7T
- LD rr,nn: 10T | LD (nn),A: 13T | LD A,(nn): 13T
- OUT (n),A: 11T | IN A,(n): 11T | OUT (C),r: 12T
- LDIR: 21T/byte (16T last) | LDI: 16T
- PUSH: 11T | POP: 10T | CALL: 17T | RET: 10T
- JR: 12T (taken) / 7T (not taken) | JP: 10T

### z88dk-ticks
For measuring actual T-states of a code path, use z88dk-ticks
emulator with `-end` at the target address. See TICKS.md in
z80-utils/test-gen/.

## Reference: isr_crt timing analysis

The CRT display refresh ISR runs at 50Hz (every 20ms). Timing from
clang bios.lis instruction analysis:

| Section | T-states | Notes |
|---------|----------|-------|
| CRT status read | 11T | acknowledge interrupt |
| DMA ch2/ch3 mask | 36T | mask both channels |
| Clear byte pointer | 15T | |
| Ch2 addr + word count | 58T | DSPSTR=0xF800, 2000 bytes |
| Ch3 word count | 26T | zero (no attributes) |
| DMA ch2/ch3 unmask | 36T | enable transfer |
| **DMA subtotal** | **~198T** | |
| Wrapper (SP save, EXX) | ~40T | isr_crt_wrapper overhead |
| Cursor update (if dirty) | ~60T | 3 port writes |
| Timer/blanking logic | ~80T | clktim, screen blank |
| **Total per invocation** | **~320-380T** | |
| **Per second (50Hz)** | **~16,000-19,000T** | ~0.4-0.5% CPU at 4MHz |

With FAST_SCROLL (circular buffer): the DMA section grows by ~40T for
computing split addresses from SCROLLOFSET (negate, add, two address
sets instead of one fixed). Total ~360-420T per invocation. Negligible
difference — the ISR cost is dominated by the port I/O, not arithmetic.

## Todo: Make CONFI.COM settings configurable in BIOS source

Currently the CONFI.COM configuration block (128 bytes at disk Track 0
offset 0x80) controls serial port settings, cursor size/blink, keyboard
mapping, and other hardware parameters. The BIOS copies this block to
CFG_ADDR (0xD500) at cold boot and reads fields from there at runtime.

The defaults are hardcoded in boot_confi.c as a binary blob. Make these
human-readable and configurable:

- Map the full 128-byte ConfiBlock layout (which bytes control what)
- Define named constants/struct fields for each setting
- SIO configuration: baud rate, data bits, parity, stop bits, handshaking
- CRT cursor: size (underline/block), blink rate, visibility
- Keyboard: repeat rate, click, national character set selection
- DMA mode values for each channel
- Any other hardware parameters controlled by CONFI.COM

Goal: change a #define in the BIOS source instead of running CONFI.COM
on the target machine. The ConfiBlock struct in bios.h already has some
field definitions — extend it to cover all 128 bytes with documented fields.

## Todo: Remove unnecessary type casts in bios.c

Several variables store addresses as `word` instead of proper pointer types,
requiring casts at every use. Changing them to pointers removes casts and
improves type safety:

- `dskad` (word → byte *): DMA buffer address, flows into flp_dma_setup()
- `dmaadr` (word → byte *): CP/M DMA address, used in memcpy for sector I/O
- FSPA struct initializers: `(DPB *)&dpb0`, `(byte *)tran0` — align field types
- `(byte *)&rstab` at line 315 — use proper fdc_result_block pointer

Ripple: dskad/dmaadr changes affect flp_dma_setup (port writes take low/high
bytes), memcpy calls, and hstbuf indexing. Not trivial but straightforward.

## Todo: 26-line display with status line (feature/26-line-status)

Plan complete. Implementation in 3 phases:

- [ ] Phase 1: CRT26 flag + DMA split (ch2: 2000B display, ch3: 80B status from BSS)
  - Modify PAR2 in bios_hw_init.c (SUB 0x3F for 26 rows)
  - Add hal_dma_atr_addr macro to hal.h
  - Update isr_crt: program ch3 address+wc for status buffer
  - Add CRT26 build flag to Makefiles
  - MAME: should work without driver changes (8275 recompute_parameters)
- [ ] Phase 2: Status line driver (callback-based, clock display)
- [ ] Phase 3: Interactive status line (SystemRequest key menu)

See: rcbios-in-c/tasks/26-line-status.md

## Todo: Serial transfer to physical RC700

- [x] Serial transfer pipeline working (2026-04-05)
  - Linux + pyserial + RTS/CTS + per-line flush: reliable at 38400 baud
  - BIOS-only hex (363 records, ~24s) via MLOAD+BDOSCCP.COM workflow
  - 16-bit checksum validator, drain-to-empty RTS flow control
- [x] RTS flow control: drain buffer to empty before re-asserting (59 vs 5300 CTS drops)
- [x] macOS FTDI: confirmed broken tcdrain() — use Linux for transfers
- [ ] IOBYTE support in BIOS for remote console via serial
- [ ] Investigate 115200 baud (SIO WR4 clock mode change)
- [ ] Build proper FTDI↔RC700 cable (see rcbios-in-c/docs/serial_cable_wiring.md)
- [ ] macOS: investigate pyftdi for direct FTDI USB control (bypass kernel driver)
- [ ] Investigate serial communication optimization (Z80 struggles with per-character interrupts at 38400)
- [ ] Investigate switch vs if-then-else codegen for Z80 (IOBYTE dispatch adds 240B, may be reducible)
- [ ] Investigate if a PC with traditional RS-232 serial port works with current cable
  - The FTDI needs rtscts=True + per-line flush() on Linux
  - A real 16550 UART handles CTS in hardware natively — may just work with crtscts
  - Check if the mini adapter pinout is compatible with a PC DB-9 COM port

## Future / Fun

- [ ] QR code generator using semi-graphics (block characters for Z80 terminal output)
- [ ] Initialize custom character generator ROM (SEM702) from BIOS
  - Character generator defined in roa375/PHE358A.MAC
  - Some BIOS versions reprogram it at boot for custom character sets
