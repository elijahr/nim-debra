## Compile-fail test: copying a PinnedScope must fail.
##
## `pinned_scope.nim` declares `{.error.}` on `=copy`. The runner
## verifies this by invoking `nim c` and asserting the substring
## "'=copy' is not available for type" appears in the compiler's
## error output.
##
## A copy is forced by reading `a` after the assignment so the
## compiler cannot rewrite `var b = a` as a move.

import debra

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)
  var a = pinScope(unpinned(handle))
  var b = a
  discard a # force a real copy, not a sink-driven move
  discard b

main()
