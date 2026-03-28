# Lessons Learned

## 2026-03-27: Direct addressing has cascading benefits

Phase 1 (direct global addressing) saved 234 bytes — more than double the 100B estimate. The cascade effect is real: eliminating register pair usage for address computation reduces spill pressure, which makes IX unused in more functions, which triggers the existing unused-IX-removal pass. When estimating optimization savings, account for second-order effects on register pressure.

## 2026-03-27: Z80.cmake needs lld enabled

The Z80.cmake cache file only enabled `clang` as a project. The PROM build needs `ld.lld` for ELF linking. Added `lld` to `LLVM_ENABLE_PROJECTS`.

## 2026-03-27: LLVM IR index-based loops are the biggest Z80 code density problem

LLVM canonicalizes `*ptr++` loops into `GEP base, index` form (good for x86 with base+index addressing, catastrophic for Z80). On Z80, pointer increment is `INC HL` (1 byte, 6 T-states) but base+index recomputation is `LD HL,base; LD BC,index; ADD HL,BC` (7+ bytes). This single IR canonicalization accounts for ~100 bytes of gap across compare_6bytes, check_sysfile, fdc_write_full_cmd, and fdc_read_data.

## 2026-03-27: BIT n,A is NOT the low-hanging fruit it appears

The `xor $80; cp $40; jr c` pattern looks wasteful but is actually a 2-bit range check `(status & 0xC0) == 0x80`, NOT a single-bit test. Both SDCC and clang generate 6 bytes for this. The real Phase 2 win needs to target loop structure, not bit testing.

## 2026-03-27: hasFP=false bug is regalloc, not ISR

After thorough investigation with verified banner timestamps:
1. ISR not saving IX was a red herring — ISRs don't use IX, callees callee-save it
2. The unused-IX-removal peephole strips PUSH IX from ISRs (fixable but not the cause)
3. The real bug: regalloc makes wrong decisions with IX allocatable. In `_fdc_read_data_from_current_location`, `ld a,$1` (return value) is dropped because regalloc moved the comparison to H and the code path `or h; jr nz` doesn't set A=1 before branching.

## 2026-03-27: Rebuild clang only after changing compiler source

The PROM doesn't need the compiler rebuilt every time — only rebuild clang (ninja -C build clang) after changing llvm-z80 source. But always `make clang_clean` before `make clang` to ensure the PROM objects are fresh. Multiple MAME failures were caused by a stale clang binary left over from a branch experiment — always rebuild clang after switching branches in llvm-z80.

## 2026-03-27: Always verify PROM binary freshness via banner timestamp

When testing PROM changes in MAME, the banner string includes a build timestamp (e.g. "CL 2026-03-27 08.37/ravn"). ALWAYS check this matches the current time to confirm the binary was actually rebuilt. Earlier MAME tests without this check produced unreliable results — conclusions about root causes may have been based on stale binaries.

## 2026-03-27: SROA causes index-based loops on Z80

The LLVM SROA (Scalar Replacement of Aggregates) pass converts pointer-increment loops (`*ptr++`) to index-based GEP (`base + index`) when promoting alloca'd pointer variables to SSA values. This is the single biggest remaining code density issue on Z80 (~90 bytes on the PROM). The frontend generates correct pointer-increment form, but SROA rewrites it. Found by tracing with `-Xclang -disable-llvm-optzns` + `opt -Os -print-after-all`.

## 2026-03-27: hasFP=false investigation — code IS different, not just BSS size

The hasFP=false change appears to produce identical disassembly but the PROM binary has many byte differences. This is because the ELF VMA addresses stay the same but the BSS section layout changes, shifting global variable addresses in the relocated binary. Always compare the actual binary, not just the disassembly. The stale listing capture was misleading.

## 2026-03-27: Always create branches for issues, record prompts

User wants: create branches for issues, create tasks/issues when planning. Record all prompts.

## 2026-03-28: SPILL_IMM8 has no implicit-def of A (static-stack only)

The SPILL_IMM8 pseudo is defined with no Defs in TableGen — correct for IX-indexed expansion (`LD (IX+d),n`, no A clobber) but wrong for static-stack BSS expansion (`LD A,imm; LD (addr),A`). The register allocator sees no A clobber and may place live values in A across the pseudo. Fix: check `isRegLiveAt(A)` and PUSH AF/POP AF in the BSS expansion path, matching SPILL_GR8. This fixed 11/25 edge-case test failures.

Lesson: when a pseudo instruction has different expansion paths with different register clobbers, audit ALL paths against the declared Defs. The path-specific clobbers must be handled at expansion time if they're not in the pseudo's Defs.

## 2026-03-28: isRegLiveAt sees unexpanded pseudos — potential hidden bugs

When `eliminateFrameIndex` processes SPILL/RELOAD pseudos left-to-right, the `isRegLiveAt` scan for later instructions sees not-yet-expanded pseudos. These pseudos don't declare A as an operand (since they don't use A in their IX-indexed form), but their static-stack expansion WILL use A. This means the liveness check may undercount A usage, leading to incorrect save/restore decisions in large functions with many spills. This is the likely root cause of ravn/llvm-z80#30 (4/10 benchmark failures).

## 2026-03-28: z88dk-ticks -trace fills disk on long programs

Never use `-trace` flag with z88dk-ticks for programs that run more than ~100K instructions. The trace output is one line per instruction and can generate terabytes for pi computations or other long-running code. Use `-trace` only with `-end` on short-running tests.

## 2026-03-28: Fair cross-compiler size comparison needs CRT exclusion

Clang's Z80 CRT is ~28 bytes (_start to _main). z88dk's CRT is ~560 bytes. For fair code size comparison, use `__code_compiler_size` from z88dk's map file (user code only, excludes CRT) and subtract _main address from clang's llvm-size output. Runtime library functions (div, mod, mul) should be INCLUDED since both compilers link them based on user code needs.

## 2026-03-27: Docker build needs clang as host compiler

After merging upstream LLVM, the build fails with gcc because newer LLVM uses clang-specific warning flags. Pass `-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++` to cmake, or ensure the Docker image uses clang as default cc/c++.
