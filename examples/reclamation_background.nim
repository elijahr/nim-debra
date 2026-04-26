# examples/reclamation_background.nim
## Background reclamation: dedicated thread for memory reclamation.
##
## ## refc compatibility
##
## This example is **incompatible with `--mm:refc`** and will skip with a
## diagnostic message under that GC. The reason is a fundamental refc design
## constraint, not a debra bug:
##
## * The worker threads allocate `Node` (a `ref`) and call `GC_ref` via
##   `managed`. The refc heap (`gch`) is thread-local
##   (`{.rtlThreadVar.}` in `system/gc.nim`), so the cell metadata lives on
##   the worker's heap.
## * The dedicated reclaimer thread later calls `GC_unref` from the destructor
##   stored in the limbo bag. That reaches into the reclaimer's `gch`, mutates
##   a refcount on a cell that doesn't belong to it, and crashes inside
##   `decRef` (`SIGSEGV` at `system/gc.nim:251`).
## * refc has no public API for cross-thread `ref` release. `ForeignCell` /
##   `setupForeignThreadGc` initialize the calling thread's own heap; they do
##   not let one thread free another thread's cells.
##
## Use `--mm:arc` or `--mm:orc` (with `-d:allowSpinlockManagedRef` for
## `Managed[ref T]`) for background reclamation patterns. Both arc and orc use
## atomic, shared refcounts and tolerate cross-thread `=destroy` / `GC_unref`.
##
## See also: `examples/reclamation_periodic.nim` for a single-threaded
## reclamation pattern that works under all GCs.

when defined(gcRefc):
  echo "reclamation_background: skipped under --mm:refc"
  echo "  refc's per-thread GC heap does not support cross-thread GC_unref."
  echo "  Use --mm:arc or --mm:orc for background reclamation patterns."
else:
  import debra
  import std/[atomics, os]

  type
    NodeObj = object
      value: int
    Node = ref NodeObj

  var
    manager: DebraManager[4]
    shouldStop: Atomic[bool]
    totalReclaimed: Atomic[int]

  proc reclaimerThread() {.thread.} =
    ## Background thread that periodically attempts reclamation.
    while not shouldStop.load(moAcquire):
      let reclaimResult = reclaimStart(addr manager)
        .loadEpochs()
        .checkSafe()

      case reclaimResult.kind:
      of rReclaimReady:
        {.cast(gcsafe).}:
          let count = reclaimResult.reclaimready.tryReclaim()
          discard totalReclaimed.fetchAdd(count, moRelaxed)
      of rReclaimBlocked:
        discard

      sleep(5)  # 5ms between attempts

  proc workerThread() {.thread.} =
    ## Worker thread that performs operations.
    let handle = registerThread(manager)

    for i in 0..<100:
      let u = unpinned(handle)
      let pinned = u.pin()

      let node = managed Node(value: i)
      let ready = retireReady(pinned)
      discard ready.retire(node)

      let unpinResult = pinned.unpin()
      case unpinResult.kind:
      of uUnpinned: discard
      of uNeutralized: discard unpinResult.neutralized.acknowledge()

      # Occasionally advance epoch
      if i mod 10 == 0:
        manager.advance()

  when isMainModule:
    manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    shouldStop.store(false, moRelaxed)
    totalReclaimed.store(0, moRelaxed)

    # Start background reclaimer
    var reclaimer: Thread[void]
    createThread(reclaimer, reclaimerThread)

    # Start worker threads
    var workers: array[2, Thread[void]]
    for i in 0..<2:
      createThread(workers[i], workerThread)

    # Wait for workers to finish
    for i in 0..<2:
      joinThread(workers[i])

    # Give reclaimer time to clean up remaining objects
    sleep(50)

    # Stop reclaimer
    shouldStop.store(true, moRelease)
    joinThread(reclaimer)

    echo "Total reclaimed by background thread: ", totalReclaimed.load(moRelaxed)
    echo "Background reclamation example completed successfully"
