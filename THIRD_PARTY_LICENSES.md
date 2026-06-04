# Third-Party Licenses

This file collects the verbatim license texts for third-party software
whose code, patterns, or interfaces nim-debra borrows from or adapts.
Each entry pins the upstream source to a specific commit so the
attribution is reproducible.

The rationale for each borrowing — what specifically was adapted, what
problem it solves, and why an in-tree reference matters — lives in the
relevant design document under `docs/design/`. This file is the legal
artifact; the design doc is the engineering record.

## atomic128

- **Project:** [atomic128](https://github.com/patternnoster/atomic128)
- **Author:** patternnoster (Dmitry Serdyuk)
- **License:** MIT
- **Pinned commit:** `d45ba3d348a9620a25552f9cf50dc7ccef05ef90`
- **What nim-debra borrows:** the GCC `__sync_val_compare_and_swap` vs.
  Clang `__atomic_compare_exchange_n` compiler-dispatch pattern used in
  16-byte (DWCAS) `compareExchange` emit bodies. atomic128's
  `atomic128_ref.hpp` documents the GCC silent-libatomic-fallback
  footgun on `__atomic_compare_exchange_16` that this dispatch works
  around. See `docs/design/2026-06-02-dwcas-design.md` (the DWCAS
  design doc, §10) for the engineering rationale.

<!-- pinned-commit: d45ba3d348a9620a25552f9cf50dc7ccef05ef90 -->

```
MIT License

Copyright (c) 2023 Dmitry Serdyuk

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
