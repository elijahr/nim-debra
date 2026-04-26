# examples/retire_multiple.nim
## Retire multiple objects within a single pinned epoch.
##
## Demonstrates chaining retires by threading `RetireReady` through
## `retireReadyFromRetired`, which is the lower-level form behind the
## `var RetireReady` overload used by `withPin` bodies.

import debra

type
  NodeObj = object
    value: int

  Node = ref NodeObj

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)

  # Enter critical section
  let pinned = unpinned(handle).pin()

  # Retire multiple nodes in a single critical section. The `var`-form
  # `retire` from `debra/convenience` rebuilds `RetireReady` for us; here we
  # do it explicitly to show the typestate transition.
  var ready = retireReady(pinned)
  let dtor = releaseDestructor[NodeObj]()

  for i in 1 .. 5:
    let node = retain Node(value: i * 10)
    echo "Retiring node with value: ", node.value
    # `var`-form retire from debra/convenience: consumes and rebuilds `ready`
    # in place. Equivalent to `let r = retire(move(ready), ...);
    # ready = retireReadyFromRetired(r)`.
    ready.retire(cast[pointer](node), dtor)

  echo "Retired 5 nodes"

  # Rebuild the Pinned context from the last RetireReady so we can unpin.
  let ctx = RetireContext[4](ready)
  let pinnedAgain =
    Pinned[4](EpochGuardContext[4](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  echo "Multiple retirement example completed"

when isMainModule:
  main()
