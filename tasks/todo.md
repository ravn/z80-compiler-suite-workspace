# Z80 Code Density Optimization Todo

## Status: SGT X,0 fix + DMA macro + high-byte peephole — CLANG BEATS SDCC

SDCC: 1910B | Clang: 1893B | Clang is 17B smaller (-0.9%)

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

- [ ] Investigate `clang -Weverything -c` on PROM sources
- [ ] Experiment with HI-Tech C to see how well it does
- [ ] Per-pair 16-bit copy cost in register allocator (ravn/llvm-z80#27)
- [ ] Tail call blocked by PUSH in IY copy (prom1_if_present: PUSH DE; POP IY;
  CALL __call_iy; RET — HasPush check falsely blocks, 1B)

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
- ravn/llvm-z80#29 — **+static-stack incorrect code in large functions** (11/25 Os failures)

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
