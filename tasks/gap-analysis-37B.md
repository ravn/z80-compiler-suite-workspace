# Code Density Gap Analysis: 37 bytes (1.9%)

SDCC: 1912B | Clang: 1949B | Gap: 37B

## Session results (2026-03-27)

### Z80IndexIV fix: -76B (2025→1949)

**Root cause**: The Z80IndexIV pass was converting efficient pointer-increment
loops (`gep ptr, 1` → `INC HL`, 1B) into base+index loops
(`gep base, index` → `LD HL,base; ADD HL,BC`, 4+B).

Pass trace confirmed Z80IndexIV is the exact pass destroying the good IR in
`compare_6bytes` — IndVarSimplify produced perfect pointer-increment form,
then Z80IndexIV rewrote it to base+index.

**Fix**: Skip Z80IndexIV when `+static-stack` is active (Z80IndexIV.cpp).
With static-stack, locals are in BSS, not IX-relative, so IX+d indexed
addressing (which the pass was designed to enable) has no benefit.

TODO: investigate whether Z80IndexIV helps non-static-stack code.

### Remaining 37B gap breakdown

**Functions where clang is LARGER:**

| Function | Clang | SDCC | Delta | Root cause |
|----------|-------|------|-------|------------|
| fdc_read_data | 173 | 134 | +39 | Signed 16-bit cmp bloat (~20B) + BSS spills |
| fdc_write_full_cmd | 83 | 65 | +18 | Multi-value BSS spill + IX loop index |
| floppy_boot | 48 | 35 | +13 | Register allocation |
| error_display_halt | 38 | 26 | +12 | RRCA+RET C vs AND+JR NZ, inlined halt_forever |
| check_sysfile | 40 | 32 | +8 | Residual index-style access |
| compare_6bytes | 20 | 17 | +3 | Still 3B larger (counter management) |
| delay | 18 | 15 | +3 | Counter loop pattern |

**Functions where clang is SMALLER (inlining wins):**

| Function | Clang | SDCC | Delta | Reason |
|----------|-------|------|-------|--------|
| fdc_read_result | 71 | 163 | -92 | Single-call-site inlining |
| fdc_get_result_bytes | 116 | 160 | -44 | Single-call-site inlining |
| boot_floppy_or_prom | 153 | 176 | -23 | Inlining + tail calls |
| fdc_sense_interrupt | 24 | 31 | -7 | Better register use |

### Top 2 remaining root causes

#### 1. Signed 16-bit comparison (~20B, ravn/llvm-z80#19)

`(int16_t)remaining > 0` generates a ~42B RLCA/SBC/AND/OR sequence.
SDCC generates ~21B using `JP PO` (overflow flag) and `JP P` (sign flag).
The Z80 ISel doesn't emit branches on PO/PE or P/M condition codes for
signed 16-bit comparisons — it materializes the result as a boolean.

#### 2. Multi-value BSS spill across CALL (~12B, ravn/llvm-z80#20)

`fdc_write_full_cmd` spills both cmd and dh to BSS across CALLs (12B total).
SDCC keeps both in BC and uses PUSH/POP (2B). The single-value PUSH/POP
peephole exists but doesn't handle multiple simultaneous spills.

### Where clang wins

Clang's `areInlineCompatible` inlines single-call-site internal functions,
saving CALL+RET overhead (4B each). This benefits main_relocated heavily:
8 init_* functions inlined = ~32B saved. SDCC calls them separately.

The inlining wins (-166B on matched functions) more than offset the losses
(+96B), which is why the total gap is only 37B despite several functions
being individually larger.
