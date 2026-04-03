# Top-level Makefile for z80 workspace
#
# After a fresh clone of llvm-z80 and rc700-gensmedet:
#   make toolchain      Build native Z80 clang compiler
#   make bios           Build BIOS with clang
#   make prom           Build PROM with clang
#   make test           Boot BIOS in MAME

# CLion-bundled cmake/ninja (no brew needed)
CMAKE = /Applications/CLion.app/Contents/bin/cmake/mac/aarch64/bin/cmake
NINJA = /Applications/CLion.app/Contents/bin/ninja/mac/aarch64/bin/ninja

LLVM_Z80 = $(CURDIR)/llvm-z80
BIOS_DIR = $(CURDIR)/rc700-gensmedet/rcbios-in-c
PROM_DIR = $(CURDIR)/rc700-gensmedet/autoload-in-c

TOOLS = clang lld llvm-objcopy llvm-objdump llvm-nm llc

.PHONY: toolchain bios prom test clean-toolchain

# ================================================================
# Z80 clang toolchain (native macOS build)
# ================================================================

toolchain: $(LLVM_Z80)/build-macos/bin/clang

$(LLVM_Z80)/build-macos/bin/clang: $(LLVM_Z80)/clang/cmake/caches/Z80.cmake
	@echo "=== Configuring LLVM-Z80 for macOS ==="
	$(CMAKE) -C $(LLVM_Z80)/clang/cmake/caches/Z80.cmake \
		-G Ninja \
		-DCMAKE_MAKE_PROGRAM=$(NINJA) \
		-S $(LLVM_Z80)/llvm -B $(LLVM_Z80)/build-macos
	@echo "=== Building Z80 clang toolchain ==="
	$(NINJA) -C $(LLVM_Z80)/build-macos $(TOOLS)
	@echo "=== Verifying ==="
	$(LLVM_Z80)/build-macos/bin/clang --version
	@echo "=== Z80 clang toolchain ready ==="

clean-toolchain:
	rm -rf $(LLVM_Z80)/build-macos

# ================================================================
# BIOS and PROM builds
# ================================================================

bios: toolchain
	$(MAKE) -C $(BIOS_DIR) bios

prom: toolchain
	$(MAKE) -C $(PROM_DIR) prom

test: bios
	$(MAKE) -C $(BIOS_DIR) mame-maxi
