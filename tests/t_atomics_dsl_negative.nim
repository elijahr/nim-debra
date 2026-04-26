# tests/t_atomics_dsl_negative.nim
##
## Compile-time only. Imports `debra/atomics` WITHOUT importing the
## DSL submodule, then asserts (via `compiles`) that the DSL methods
## are not reachable. If `import debra/atomics` ever transitively
## re-exports the DSL the assertions in this file will start
## compiling and `nim check` will pass when it should not.
##
## Run via `nim check`. Not a unittest2 file; no `test`/`suite`.

import debra/atomics

static:
  var a: Atomic[int]
  doAssert not compiles(a.relaxed()), "relaxed() leaked into core debra/atomics"
  doAssert not compiles(a.relaxed(1)), "relaxed(v) leaked into core debra/atomics"
  doAssert not compiles(a.acquire()), "acquire() leaked into core debra/atomics"
  doAssert not compiles(a.release(1)), "release(v) leaked into core debra/atomics"
  doAssert not compiles(a.sequential()), "sequential() leaked into core debra/atomics"
  doAssert not compiles(a.sequential(1)), "sequential(v) leaked into core debra/atomics"
