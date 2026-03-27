# Z80 Code Density Optimization Todo

## Status: Multi-load BSS spill→PUSH/POP + LIFO safety fix

SDCC: 1912B | Clang: 1944B | Gap: 32B (1.7%)

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

- [ ] Signed 16-bit comparison bloat (~20B, ravn/llvm-z80#19)
  - `(int16_t)remaining > 0` generates RLCA/SBC/AND/OR (~42B) instead of
    JP PO/JP P pattern (~21B) that uses Z80 overflow/sign flags
  - Affects: fdc_read_data_from_current_location (+39B total, ~20B from this)
  - Root cause: `icmp sgt i16 X, 0` normalizes to `icmp slt i16 0, X` but
    `isConstZero(LHS)` check was missing (only RHS checked). Fixed that, but
    the SDCC pattern (JP PO,+2; XOR $80) requires MBB splitting which crashes
    in branch relaxation pass. Needs careful MBB architecture — parked.
  - Approaches tried: pseudo instruction (OOM), direct MBB split in ISel (crash
    in branch relaxation), expandPostRAPseudo (OOM). Need to either:
    a. Emit the MBB split in Z80LowerSelect (pre-regalloc, similar to G_SELECT)
    b. Use a branchless algorithm that doesn't need JP PO skip
    c. Emit as a late pseudo expanded after branch relaxation

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

## Issues filed (ravn/llvm-z80)
- ravn/llvm-z80#19 — Signed 16-bit comparison bloat (~20B)
- ravn/llvm-z80#20 — Multi-value BSS spill across CALL (~12B)
- ravn/llvm-z80#15 — Loop index→pointer conversion (~90B) — FIXED (Z80IndexIV disabled)
- ravn/llvm-z80#16 — PUSH/POP instead of IX-indexed spills (~40B)
- ravn/llvm-z80#12 — OR/AND (HL) memory operand fusion (~10B)
- ravn/llvm-z80#17 — hasFP=false regalloc bug: infinite loop in fdc_write_full_cmd (FIXED)
- ravn/llvm-z80#18 — Known-value register copy optimization

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
