TinyPI
------
Copyright (c) 2017-2024 Fabrice Bellard

TinyPI is a small C program (14 kB on x86_64 Linux) without external
dependency computing millions of digits of Pi using the Chudnovsky
formula. The running time and memory usage are nearly proportional to
the number of computed digits.

For optimal performance the program should be run on a 64 bit CPU. The
maximum number of digits is practically unlimited (about 10^16
digits). A 32 bit version is available but it is limited to about 10
million digits.

1) History
----------

This program started in 2017 as a challenge to compute the digits of
Pi in near linear time using the smallest program. Later versions lead
to the LibBF library.

Design choices:

- Formula: The Chudnovsky formula was chosen because it gives a better
performance than the various arctangent formulas. However, it is
slightly more costly in terms of code complexity because a square root
is needed in addition to the division.

- Base: base 10 representation was used even if it is slower than base
  2 to have a smaller and simpler code. All the numbers are stored as
  floating point numbers in base 10^N (N=19 with 64 bit words, N=9
  with 32 bit words).

- Large multiplications: the Number Theoretic Transform (NTT) was used
  instead of the Discrete Fourier Transform (DFT) so that the program
  does rely on floating point operations. No SIMD code is used to keep
  the program simple.

2) License
----------

MIT license.
