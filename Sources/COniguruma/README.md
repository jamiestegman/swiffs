Vendored [Oniguruma](https://github.com/kkos/oniguruma) v6.9.10 (BSD-2-Clause,
see `COPYING`), the regular expression engine used by TextMate grammars (and by
VS Code / Shiki's WASM engine). Unmodified sources; `src/config.h` and
`include/swiffs_onig_shim.h` are the only added files. The POSIX/GNU
compatibility layers and `mktable.c` are omitted.
