# Z80 Code Density Optimization Todo

## Status: Phases 1+narrowing complete

SDCC: 1912B | Clang: 2106B | Gap: 194B (10%)

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

## Remaining (prioritized)

- [ ] **hasFP=false regalloc bug** (~70B savings blocked, HIGHEST PRIORITY)
  - Saves ~70B code (2106→2036 with ISR fix) but MAME boot FAILS
  - All results verified with banner timestamp
  - **NOT an ISR issue.** Explicitly adding PUSH IX/POP IX to ISR
    prologue/epilogue (and preventing peephole removal) didn't fix it.
    The ISRs don't use IX/IY themselves — callees save them if needed.
  - **ROOT CAUSE: regalloc instability.** With IX allocatable (hasFP=false),
    the register allocator makes different decisions. In
    `_fdc_read_data_from_current_location`, the comparison result is
    moved to H register but the return value `ld a,$1` is dropped —
    a real code generation bug.
  - The unused-IX-removal peephole also strips PUSH IX/POP IX from ISRs
    (fixed by checking `hasFnAttribute("interrupt")` but ISR wasn't
    the actual failure cause).
  - Approach: isolate which function(s) generate wrong code by compiling
    individual functions with hasFP=true vs false and testing

- [ ] Loop index→pointer conversion (~90B, largest remaining gap)
  - Root cause: **SROA pass** (pass 2213) converts pointer increment to
    base+index GEP when promoting alloca'd pointers to SSA.
    Frontend at -Os without LLVM opts: `getelementptr ptr %ap, i16 1` (correct)
    After SROA: `getelementptr ptr %base, i16 %index` (recomputes every iteration)
  - On Z80, pointer increment (INC HL, 1B) is far cheaper than
    recompute from base+index (LD HL,(bss); ADD HL,BC = 7B+)
  - Affects: compare_6bytes (+42B), check_sysfile (+49B),
    fdc_write_full_cmd (+36B loop)
  - Approaches:
    a. Post-SROA pass to convert index-based GEP back to pointer-increment
    b. Target hook in SROA to prefer pointer-increment on register-poor targets
    c. Z80-specific MachineIR pass to detect BSS-reload+ADD+load pattern

- [ ] PUSH/POP instead of IX-indexed spills across CALLs (~40B)
  - 11 functions use IX frames, many only for cross-call temp storage
  - IX overhead: 8B setup + 3B per store + 3B per load
  - PUSH/POP: 0B setup + 1B push + 1B pop
  - Example: fdc_select_drive_cylinder_head uses IX for 2 temps = 20B IX
    overhead, would be 8B with PUSH/POP
  - Approach: post-RA peephole or spiller change

- [x] ~~OR (HL) / AND (HL) fusion~~ — not worth it, only 3 SDCC instances,
  clang's direct addressing is equivalent. Closed #12.

- [ ] MAME boot test to verify PROM correctness

- [x] Interleaved C source in clang listing (make clang_src_lis)

- [ ] Investigate `clang -Weverything -c` on PROM sources

## Issues filed
- llvm-z80/llvm-z80#10 — Loop index→pointer conversion (~90B)
- llvm-z80/llvm-z80#11 — PUSH/POP instead of IX-indexed spills (~40B)
- llvm-z80/llvm-z80#12 — OR/AND (HL) memory operand fusion (~10B)
- llvm-z80/llvm-z80#14 — hasFP=false regalloc bug (~70B blocked)

## Parked (investigated, not worth pursuing now)

- [x] BIT n,A branch fusion — investigated, AND+JR patterns already efficient
  (same size as BIT+JR). The `xor $80; cp $40` pattern is a range check,
  not a single-bit test. PostRACompareMerge correctly handles redundant OR A.

- [x] 8→16-bit comparison promotion — this IS happening but the root cause
  is the loop index→pointer problem (Phase 2), not type legalization.
  The comparisons themselves are i8, but the loop counter and pointer
  arithmetic are i16 because of index-based GEP.

## Metrics

| Date | SDCC | Clang | Gap | Change |
|------|------|-------|-----|--------|
| 2026-03-26 | 1912 | 2352 | 440 (23%) | baseline (post-merge) |
| 2026-03-27 | 1912 | 2118 | 206 (11%) | Phase 1: direct addressing |
| 2026-03-27 | 1912 | 2106 | 194 (10%) | Narrow i16 cmp through zext/sext |
| 2026-03-27 | 1912 | 2024 | 112 (6%) | hasFP=false (blocked by runtime bug) |
