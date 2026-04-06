# Session 11: PROM Optimization Gap Analysis

Date: 2026-04-06
PROM size: Clang 1791B vs SDCC 1910B (clang 119B smaller, -6.2%)

## Method

Systematic analysis of clang/prom.lis (full disassembly) function by function,
cross-referenced with SDCC assembly output and known Z80 optimization idioms.
All findings verified against actual bytes in the listing.

## New Issues Filed

| Issue | Title | Bytes | Category |
|-------|-------|-------|----------|
| #54 | Fall-through JP elimination | 6B | linker/layout |
| #55 | ADD HL,DE commutativity | 6B | peephole |
| #56 | Shift-left-7 strength reduction | 5B | ISel/peephole |
| #57 | Comparison reversal (LD D,A; LD A,imm; CP D → CP imm) | 3B | ISel |
| #58 | JP where JR suffices (branch relaxation) | 3B | post-RA |
| #59 | 16-bit loop counter where 8-bit suffices | 6B | legalization |
| #60 | Redundant LD A,reg when A unchanged | 4B | peephole |
| #61 | Missing DEC (HL) / INC (HL) for in-memory ops | 4B | ISel |

**Total potential: ~37 bytes** → would bring PROM to ~1754B.

## Fixes Implemented This Session

| Issue | Title | Actual Savings | Commit |
|-------|-------|----------------|--------|
| #59 | Narrow 16-bit loop compare to 8-bit CP | -2B | 0387305 |
| #56 | SHL 6-7 via RRCA+AND | -4B | cc9a945 |
| #55 | ADD HL,DE commutativity peephole | -6B | cb159c6 |
| #57 | Comparison reversal (post-RA peephole) | -2B | 5fb29f0 |
| #61 | In-memory DEC (HL) / INC (HL) | -6B | 511ace7 |

**Total actual: -20B** (1791B → 1771B). Estimates vs actuals:
- #59 estimated 6B, got 2B (comparison only, not counter narrowing — filed #62)
- #56 estimated 5B, got 4B (SHL 7 only instance, no SHL 6)
- #55 estimated 6B, got 6B (exact match)
- #57 estimated 3B, got 2B (branch flip is same size)
- #61 estimated 4B, got 6B (OR A removal added +1B per DEC instance)

## Session 12 Fixes

| Issue | Title | Actual Savings | Notes |
|-------|-------|----------------|-------|
| #58 | JP→JR branch shortening | -4B | All JP Z/NZ/C/NC → JR; BranchRelaxation widens out-of-range |
| #60 | Redundant LD A,reg removal | 0B | Peephole works, but all 3 PROM instances are cross-block |

**Total session 12: -4B** (1771B → 1767B).
- #58 estimated 3B, got 4B (2 infinite loops also shortened)
- #60 estimated 4B, got 0B (all instances have branch targets creating MBB boundaries)

## Issues Not Yet Fixed

| Issue | Title | Est. | Status |
|-------|-------|------|--------|
| #54 | Fall-through JP elimination | 6B | Cross-section, needs linker-level opt |
| #60 | Redundant LD A,reg (cross-block) | 4B | Intra-block peephole done, cross-block needed |
| #62 | IV narrowing (counter register pair) | 4B | Open — follow-up to #59 |

## Previously Known Issues (still applicable to PROM)

| Issue | Title | Est. Impact |
|-------|-------|-------------|
| #7 | DJNZ, LDIR, CPIR, CP (HL) | ~7B |
| #20 | Multi-value BSS spill across CALL | ~33B remaining |
| #48 | Eliminate BSS store/load for constant pointer locals | significant |
| #53 | Static-stack trivially-constant locals to BSS | significant |

## SDCC Patterns Not Yet Matched

These are patterns SDCC uses that clang doesn't, derived from comparing assembly:

1. **DEC (HL) / INC (HL)** — in-memory increment/decrement (filed as #61)
2. **LD (HL),#imm** — constant store without loading A first
3. **Conditional RET (RET Z, RET C)** — Z80BranchCleanup.cpp has this but it's
   disabled (`#if 0`) due to `-ffunction-sections` crash
4. **Function fall-through** — SDCC deliberately orders functions for fall-through;
   clang always emits JP between adjacent functions (filed as #54)
5. **RRCA for bit extraction** — SDCC uses `RRCA; AND $80` for bit-to-position;
   clang uses repeated ADD A,A (filed as #56)
6. **SUB for dead-A comparison** — SDCC uses SUB instead of CP when A is dead
   (same size, but sometimes enables further peephole opportunities)

## Backend TODOs Found

1. **BSS overlay optimization** (Z80AsmPrinter.cpp) — call-graph-based BSS sharing,
   parked due to hasFP=false interaction. Could reduce total BSS significantly.
2. **Conditional RET** (Z80BranchCleanup.cpp) — entirely disabled (`#if 0`),
   crashes with -ffunction-sections. SDCC uses RET Z/RET C extensively.
3. **Z80IndexIV for non-static-stack** (Z80IndexIV.cpp) — uninvestigated whether
   the pass helps when IX+d addressing is available.

## Findings Not Worth Filing

- `calc_size_of_current_track` loop restructuring: would save ~3B but requires
  ISel-level loop transform, not a peephole. Low ROI.
- `fdc_detect_sector_size_density` return staging through D: saves ~2B but the
  shared exit block pattern is correct for multiple return paths. Edge case.
- `compare_6bytes` DJNZ: B is occupied as pointer (BC=comparison pointer),
  can't use DJNZ without restructuring register allocation. Already known (#7).
