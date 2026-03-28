This project is for experimenting with the llvm-z80 backend to see if AI (notably Claude Code) can bring it into a usable state for my pet project of upgrading firmware and BIOS for the RC700 machine to modern tooling.  

Focus is on teaching llvm-z80 that the Z80 has different properties than modern CPUs and use that knowledge to allow for non-intuitive optimizations.

Right now several github repositories are made available as submodules.  Three categories:

* Compilers:  my forks of the official images or work in progress.  If bugs are found, pull requests could be made.
* Emulators:  Currently MAME is active but others exist.
* Test code:  rc700-gensmedet, and zmc-cpm.

The idea is to have lots of code compiled by all compilers, and then examine the output.  If any of them are smaller or faster than what llvm-z80 generates, then investigate thoroughly to see if and how to apply these optimizations to llvm-z80. 


This is my first adventure with AI-assisted programming, so it is learning while doing.

/ravn 2026-03-28
