# examples/reclamation_background.nim
## Background epoch-advancement thread paired with per-worker reclamation.
##
## Each thread reclaims its own retired objects: cross-thread reclamation is
## not supported in DEBRA+ because the limbo bag list is mutated by the owning
## thread without synchronization. A dedicated background thread is still
## useful for driving the global epoch forward so workers' retires become
## eligible for reclamation; the workers themselves call `reclaimNow(handle)`
## on a cadence.
##
## ## refc compatibility
##
## This example is **incompatible with `--mm:refc`** and will skip with a
## diagnostic message under that GC. The reason is a refc design constraint,
## not a debra bug:
##
## * The worker threads allocate `Node` (a `ref`) and `retain` it, which calls
##   `GC_ref`. The refc heap (`gch`) is thread-local (`{.rtlThreadVar.}` in
##   `system/gc.nim`), so the cell metadata lives on the worker's heap.
## * If a different thread later ran the destructor (which does `GC_unref` via
##   `releaseDestructor`), it would mutate a refcount on a cell that doesn't
##   belong to it, and crash inside `decRef`.
## * refc has no public API for cross-thread `ref` release. arc and orc use
##   atomic, shared refcounts and tolerate cross-thread `=destroy` /
##   `GC_unref`.
##
## Per-thread reclamation avoids the cross-thread `GC_unref` problem because
## the same worker thread that allocated a node also frees it. Under refc the
## example would still run safely as long as we never crossed threads, but we
## skip here for consistency.
##
## See also: `examples/reclamation_periodic.nim` for a single-threaded
## reclamation pattern.

when defined(gcRefc):
  echo "reclamation_background: skipped under --mm:refc"
  echo "  Use --mm:arc or --mm:orc for the cross-thread retain/release pattern."
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

  proc epochDriverThread() {.thread.} =
    ## Background thread that periodically advances the global epoch.
    ##
    ## This thread does NOT reclaim on behalf of the workers: each worker
    ## reclaims its own retired objects. Driving the epoch forward unblocks
    ## reclamation in workers that are not actively advancing (e.g., because
    ## their hot path is too tight to use `advanceEvery`).
    while not shouldStop.load(moAcquire):
      manager.advance()
      sleep(5) # 5ms cadence

  proc workerThread() {.thread.} =
    ## Worker thread that retires and reclaims its own objects.
    {.cast(gcsafe).}:
      let handle = registerThread(manager)
      let dtor = releaseDestructor[NodeObj]()

      for i in 0 ..< 100:
        withPin(handle):
          let node = retain Node(value: i)
          it.retire(cast[pointer](node), dtor)

        # Reclaim our own bag occasionally. The background thread keeps the
        # global epoch advancing, so most of these passes find work.
        if i mod 10 == 9:
          let count = reclaimNow(handle)
          discard totalReclaimed.fetchAdd(count, moRelaxed)

      # Drain remaining retired objects before the worker exits, otherwise
      # they leak (no other thread can reclaim them).
      for _ in 0 ..< 4:
        manager.advance()
      let count = reclaimNow(handle)
      discard totalReclaimed.fetchAdd(count, moRelaxed)

  when isMainModule:
    manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    shouldStop.store(false, moRelaxed)
    totalReclaimed.store(0, moRelaxed)

    # Start background epoch driver
    var driver: Thread[void]
    createThread(driver, epochDriverThread)

    # Start worker threads
    var workers: array[2, Thread[void]]
    for i in 0 ..< 2:
      createThread(workers[i], workerThread)

    # Wait for workers to finish
    for i in 0 ..< 2:
      joinThread(workers[i])

    # Stop epoch driver
    shouldStop.store(true, moRelease)
    joinThread(driver)

    echo "Total reclaimed across workers: ", totalReclaimed.load(moRelaxed)
    echo "Background reclamation example completed successfully"
