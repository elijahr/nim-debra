## debra/atomics/dsl
##
## Symmetric `.relaxed/.acquire/.release/.sequential` shorthand for
## load and store. Mirrors `commit 8fb4717
## src/lockfreequeues/atomic_dsl.nim` so the lockfreequeues port is a
## one-line `import` swap.
##
## Symmetry rule (design doc section 2):
##   * `.relaxed()`        load,  moRelaxed
##   * `.relaxed(v)`       store, moRelaxed
##   * `.acquire()`        load,  moAcquire        (load-only)
##   * `.release(v)`       store, moRelease        (store-only)
##   * `.sequential()`     load,  moSequentiallyConsistent
##   * `.sequential(v)`    store, moSequentiallyConsistent
##
## `compareExchange` and friends stay out of the DSL. This module is
## opt-in; `import debra/atomics` does NOT bring it in.

import ../atomics

proc relaxed*[T](loc: var Atomic[T]): T {.inline.} =
  ## Load `loc` with moRelaxed.
  loc.load(moRelaxed)

proc relaxed*[T](loc: var Atomic[T], value: T) {.inline.} =
  ## Store `value` into `loc` with moRelaxed.
  loc.store(value, moRelaxed)

proc acquire*[T](loc: var Atomic[T]): T {.inline.} =
  ## Load `loc` with moAcquire. Load-only by design: moAcquire is not
  ## a valid store order.
  loc.load(moAcquire)

proc release*[T](loc: var Atomic[T], value: T) {.inline.} =
  ## Store `value` into `loc` with moRelease. Store-only by design:
  ## moRelease is not a valid load order.
  loc.store(value, moRelease)

proc sequential*[T](loc: var Atomic[T]): T {.inline.} =
  ## Load `loc` with moSequentiallyConsistent.
  loc.load(moSequentiallyConsistent)

proc sequential*[T](loc: var Atomic[T], value: T) {.inline.} =
  ## Store `value` into `loc` with moSequentiallyConsistent.
  loc.store(value, moSequentiallyConsistent)
