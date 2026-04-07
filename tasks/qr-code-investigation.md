# QR Code Display Investigation (Session 12)

Date: 2026-04-06/07

## Goal

Display a QR code on the RC700 boot screen using Intel 8275 semigraphic
characters (2x3 blocks from the ROA327 character ROM).

## QR Parameters Chosen

- **URL**: `github.com/ravn/rc700-gensmedet` (31 bytes)
- **Version**: 2 (25x25 modules)
- **Error correction**: Level L (32 byte capacity)
- **Module scaling**: 2x2 pixels per QR module
- **Quiet zone**: 2 modules each side
- **Display size**: 29 chars x 20 rows (2x3 blocks) or 29x29 (2x2 blocks)

## What Works

1. **QR bitmap generation** (`gen_qr.py`): Python script using `qrcode` library
   generates correct QR data. Verified by rendering to PNG and scanning.

2. **Pre-rendered semigraphic screen data**: Python script pre-computes
   ROA327 character codes for each 2x3 block. Verified correct by simulation.

3. **GPA0 field attribute**: The 8275 field attribute 0x84 (GPA0=1) DOES
   activate the ROA327 semigraphic ROM in MAME, but ONLY when using the
   correct CRT parameters. The original PROM parameters (par3=0x9A, par4=0x5D)
   work. The BIOS parameters (par3=0x7A, par4=0x6D) also work.

4. **Solid fill test**: Writing 0x7F (all blocks set) with GPA0 active
   produces a bright solid rectangle. Semigraphic encoding confirmed working.

## Issues Found

### 1. CRT Parameter Sensitivity

The original PROM init_crt used parameters that didn't activate GPA0 in
earlier tests. Switching to parameters matching the original ROA375 PROM
assembly (roa375.asm) fixed GPA0 activation:
```
par1=0x4F  (80 chars/row)
par2=0x98  (25 rows, V=2)
par3=0x9A  (underline=9, 11 lines/char)
par4=0x5D  (transparent attrs, blink underline cursor)
```

### 2. Horizontal Stripes Between Character Rows

MAME's 8275 emulation renders a 1-pixel dark gap between each character
row, even when the character ROM has all 11 scanlines set (code 0x7F).
This creates visible horizontal stripes through the QR code.

The rc700 emulator (~/git/rc700) may not have this artifact — it has
its own 8275 implementation. Not verified (screencapture permission issue).

### 3. ROA327 Block Zone Layout vs Character Height

The ROA327 ROM block patterns use fixed scanline zones within 11-line cells:
- Top zone: lines 0-2 (3 scanlines)
- Middle zone: lines 3-6 (4 scanlines)
- Bottom zone: lines 7-10 (4 scanlines)

With reduced character heights:
- **6 lines/char**: only top (0-2) + partial mid (3-5) visible. Bottom invisible.
- **7 lines/char**: top (0-2) + mid (3-6) visible. Bottom invisible. 
  Gap-free for 2x2 blocks using only bits 0-3.
- **9 lines/char**: top + mid visible, partial bottom (7-8). Striped.
- **11 lines/char**: all zones visible but MAME shows inter-row gaps.

### 4. DMA Dual-Channel Display

The original ROA375 PROM uses TWO DMA channels (Ch2 + Ch3) for circular
scroll buffer display. The C rewrite only used Ch2. For QR display,
Ch3 should be explicitly disabled (`dma_mask(3)`) to prevent interference.

### 5. PROM Size Impact

- QR bitmap (packed): 79 bytes
- Pre-rendered screen data: 580 bytes (29x20) or 625 bytes (25x25)
- Runtime renderer: ~400 bytes compiled (nested loops with byte arithmetic)
- Pre-rendered approach is simpler and avoids Z80 codegen issues

Total with pre-rendered 2x3: ~580 bytes data + ~50 bytes display_qr code.
PROM goes from 1766B to ~2400B (still under 4KB MAME limit, but exceeds
2KB hardware limit).

## Files Created (not committed)

- `autoload-in-c/gen_qr.py` — QR code generator script
- `autoload-in-c/clang/qr_data.h` — generated QR screen data (580 bytes)

## Next Steps

1. **Test on rc700 emulator** to see if horizontal stripes are a MAME-only
   artifact. The rc700 emulator handles semigraphics via `ATTR_SEMI` flag
   in screen.c.

2. **Consider 7-line characters** with 2x2 blocks (top+mid zones only).
   Eliminates bottom zone truncation. Needs 29x29=841 bytes of screen
   data and more display rows (not feasible at 25 rows unless quiet zone
   is removed).

3. **Consider making QR conditional** on PROM size: only include if the
   PROM fits in 4KB (for MAME testing), not in 2KB production builds.

4. **Investigate MAME 8275 inter-row gap**: may be a bug in the MAME
   i8275 device emulation. The 8275 should render character rows
   contiguously with no blank lines between them.
