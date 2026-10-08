## Verify nimony-gated arms and ARC baseline in nim-debra.
##
## The continue-on-error nimony CI step validates actual nimony compilation;
## this test ensures the SMR / atomics baseline compiles and runs cleanly
## while nimony branches are evaluated.

import debra

when defined(nimony):
  echo "nimony build detected; executing debra nimony baseline"
else:
  echo "standard Nim arc baseline"

type
  NodeObj = object
    value: int

  Node = ref NodeObj

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)

  let u = unpinned(handle)
  let pinned = u.pin()

  let node = retain Node(value: 42)
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](node), releaseDestructor[NodeObj]())

  let unpinResult = pinned.unpin()
  case unpinResult.kind
  of uUnpinned:
    discard
  of uNeutralized:
    discard unpinResult.neutralized.acknowledge()

  let reclaimResult = reclaimStart(addr manager).loadEpochs().checkSafe()
  case reclaimResult.kind
  of rReclaimReady:
    discard reclaimResult.reclaimready.tryReclaim()
  of rReclaimBlocked:
    discard

  echo "debra nimony/arc baseline OK"

when isMainModule:
  main()
