# tests/t_neutralize.nim

import unittest2
import debra/atomics
import std/os

import debra/limbo
import debra/types
import debra/thread_id
import debra/signal
import debra/typestates/neutralize

# Thread state for helper threads
var
  helperReady: Atomic[bool]
  helperShouldExit: Atomic[bool]
  helperReceivedSignal: Atomic[bool]
  helperThreadIdSlot: Atomic[ThreadId]
  helperSlotIdx: Atomic[int]

proc resetHelperState() =
  helperReady.store(false, moRelaxed)
  helperShouldExit.store(false, moRelaxed)
  helperReceivedSignal.store(false, moRelaxed)
  helperThreadIdSlot.store(InvalidThreadId, moRelaxed)
  helperSlotIdx.store(-1, moRelaxed)

proc helperThreadProcCrossSlot() {.thread.} =
  ## Helper thread that:
  ##   1. Installs the SIGUSR1 handler.
  ##   2. Wires its threadvars so the handler treats it as registered at
  ##      `helperSlotIdx` of the manager published via `setGlobalManager`.
  ##   3. Publishes its own pthread handle into `helperThreadIdSlot` so
  ##      the main test thread can populate `mgr.threads[idx].threadId`.
  ##   4. Parks until told to exit, so SIGUSR1 delivered asynchronously
  ##      runs against this thread's address space (and threadvars).
  installSignalHandler()
  let idx = helperSlotIdx.load(moAcquire)
  threadLocalIdx = idx
  threadLocalRegistered = true
  helperThreadIdSlot.store(currentThreadId(), moRelease)
  helperReady.store(true, moRelease)
  while not helperShouldExit.load(moAcquire):
    sleep(1)
  # Tear down threadvars before exiting so a stray late signal cannot
  # land on a partially destroyed stack.
  threadLocalRegistered = false
  threadLocalIdx = 0

suite "Neutralize typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = DebraManager[4]()
    mgr.globalEpoch.store(1'u64, moRelaxed)
    mgr.activeThreadMask.store(0'u64, moRelaxed)
    for i in 0 ..< 4:
      mgr.threads[i].epoch.store(0'u64, moRelaxed)
      mgr.threads[i].pinned.store(false, moRelaxed)
      mgr.threads[i].neutralized.store(false, moRelaxed)
      mgr.threads[i].threadId.store(InvalidThreadId, moRelaxed)

  test "scanStart creates ScanStart":
    let s = scanStart(addr mgr)
    check s is ScanStart[4]

  test "loadEpoch transitions to Scanning":
    let s = scanStart(addr mgr)
    mgr.globalEpoch.store(10'u64, moRelaxed)
    let scanning = s.loadEpoch()
    check scanning is Scanning[4]
    check scanning.globalEpoch == 10'u64

  test "scanAndSignal sends signals to stalled threads":
    # Setup: thread 0 is pinned at epoch 1 (current thread)
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0001'u64, moRelaxed)
    mgr.threads[0].pinned.store(true, moRelaxed)
    mgr.threads[0].epoch.store(1'u64, moRelaxed)
    mgr.threads[0].threadId.store(currentThreadId(), moRelaxed)

    let scanning = scanStart(addr mgr).loadEpoch()
    let complete = scanning.scanAndSignal()
    check complete is ScanComplete[4]
    # Signal count is 0 because we skip signaling ourselves
    check complete.signalsSent == 0

  test "scanAndSignal does not signal threads within threshold":
    # Setup: thread 0 is pinned at epoch 9 (only 1 behind)
    # Use current thread so we don't need a real helper
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0001'u64, moRelaxed)
    mgr.threads[0].pinned.store(true, moRelaxed)
    mgr.threads[0].epoch.store(9'u64, moRelaxed)
    mgr.threads[0].threadId.store(currentThreadId(), moRelaxed)

    let scanning = scanStart(addr mgr).loadEpoch(epochsBeforeNeutralize = 2)
    let complete = scanning.scanAndSignal()
    check complete.signalsSent == 0 # Not stalled enough (epoch 9 >= threshold 8)

  test "scanAndSignal delivers cross-slot signal end-to-end":
    ## End-to-end regression: scanAndSignal -> sendSignal(SIGUSR1) ->
    ## handler runs in helper thread context -> handler walks
    ## DebraManager.threads with the captured stride -> flips slot 1's
    ## pinned/neutralized -> leaves slot 0's limbo-bag pointers intact.
    ##
    ## Before the threadStateStrideBytes fix, the handler walked with a
    ## hard-coded stride of 32 bytes. For a helper registered at slot 1,
    ## the handler aimed at byte offset `headerSize + 1 * 32`, which on
    ## the real 64-byte ThreadState landed inside slot 0's currentBag
    ## pointer field. The test below would have failed in three ways:
    ##   * `signalsSent` would still be 1 (the signal IS sent), but
    ##   * slot 1's pinned/neutralized would NEVER flip (we'd time out
    ##     waiting), and
    ##   * slot 0's currentBag sentinel would be clobbered to
    ##     `cast[ptr LimboBag](false)` == nil.
    ## The strengthened test asserts all three of those properties
    ## (waits with bounded timeout, then asserts slot 1 mutated and
    ## slot 0 sentinels intact).
    resetHelperState()

    # Sentinels in slot 0 to detect cross-slot corruption. Low byte is
    # non-zero so a buggy handler that interprets these bytes as
    # `Atomic[bool]` would read `true` and overwrite them.
    let sentinelCurrentBag = cast[ptr LimboBag](0xDEADBEEFCAFEBABE'u64)
    let sentinelLimboTail = cast[ptr LimboBag](0xFEEDFACE12345678'u64)
    mgr.threads[0].currentBag = sentinelCurrentBag
    mgr.threads[0].limboBagTail = sentinelLimboTail
    mgr.threads[0].pinned.store(false, moRelaxed)
    mgr.threads[0].neutralized.store(false, moRelaxed)
    mgr.threads[0].epoch.store(0'u64, moRelaxed)
    mgr.threads[0].threadId.store(InvalidThreadId, moRelaxed)

    # Tell the helper which slot it should claim.
    helperSlotIdx.store(1, moRelease)

    var helperThread: Thread[void]
    createThread(helperThread, helperThreadProcCrossSlot)

    # Wait for helper to publish its pthread handle and finish wiring
    # its threadvars.
    while not helperReady.load(moAcquire):
      sleep(1)
    let helperTid = helperThreadIdSlot.load(moAcquire)
    let helperIsValid = helperTid.isValid
    let helperIsDifferent = helperTid != currentThreadId()
    check helperIsValid
    check helperIsDifferent

    # Configure manager so scanAndSignal targets slot 1 (the helper):
    #   - active mask has slot 1 set (slot 0 inactive so it isn't
    #     considered),
    #   - slot 1 is pinned at a stalled epoch (below threshold),
    #   - slot 1's threadId is the helper's pthread handle.
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0010'u64, moRelaxed)
    mgr.threads[1].pinned.store(true, moRelaxed)
    mgr.threads[1].neutralized.store(false, moRelaxed)
    mgr.threads[1].epoch.store(7'u64, moRelaxed)
    mgr.threads[1].threadId.store(helperTid, moRelease)

    # Publish manager so the SIGUSR1 handler running in the helper can
    # locate slot 1 with the correct stride.
    setGlobalManager(addr mgr)

    let scanning = scanStart(addr mgr).loadEpoch(epochsBeforeNeutralize = 2)
    let complete = scanning.scanAndSignal()

    # scanAndSignal counts the signals it sends (synchronous) - this
    # asserts the cross-slot delivery path was actually exercised.
    check complete.signalsSent == 1

    # Signal delivery to another thread is asynchronous, so wait for
    # the helper's slot to flip. Bounded by 2 seconds; the handler
    # path is microseconds in practice.
    var deadlineMs = 2000
    while deadlineMs > 0 and not mgr.threads[1].neutralized.load(moAcquire):
      sleep(1)
      dec deadlineMs

    # Capture all observed state BEFORE tearing down (mirrors the
    # t_signal regression test pattern).
    let observedSlot1Pinned = mgr.threads[1].pinned.load(moAcquire)
    let observedSlot1Neutralized = mgr.threads[1].neutralized.load(moAcquire)
    let observedSlot0CurrentBag = mgr.threads[0].currentBag
    let observedSlot0LimboTail = mgr.threads[0].limboBagTail
    let observedSlot0Pinned = mgr.threads[0].pinned.load(moAcquire)
    let observedSlot0Neutralized = mgr.threads[0].neutralized.load(moAcquire)
    let observedSlot0Epoch = mgr.threads[0].epoch.load(moAcquire)

    # Defuse the slot 0 sentinel pointers before `=destroy` runs so
    # that even if a regression corrupted them into a bogus list head,
    # the destructor's bag-walk doesn't crash and mask the assertions.
    mgr.threads[0].currentBag = nil
    mgr.threads[0].limboBagTail = nil

    # Tear down the helper. Clear the global manager pointer BEFORE
    # the helper exits so a late spurious signal can't dereference a
    # stale pointer.
    setGlobalManager(cast[pointer](nil))
    helperShouldExit.store(true, moRelease)
    joinThread(helperThread)

    # Slot 1 (the real cross-slot target) must have been flipped.
    check observedSlot1Pinned == false
    check observedSlot1Neutralized == true

    # Slot 0 must be untouched: sentinels intact, flags/epoch unchanged.
    check observedSlot0CurrentBag == sentinelCurrentBag
    check observedSlot0LimboTail == sentinelLimboTail
    check observedSlot0Pinned == false
    check observedSlot0Neutralized == false
    check observedSlot0Epoch == 0'u64

  test "extractSignalCount gets count from ScanComplete":
    # This test validates typestate transitions and count extraction
    # without needing real signals
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0000'u64, moRelaxed) # No threads registered

    let complete = scanStart(addr mgr).loadEpoch().scanAndSignal()
    let count = complete.extractSignalCount()
    check count == 0

  test "threshold calculation with low epoch":
    # When globalEpoch is less than epochsBeforeNeutralize, threshold should be 0
    mgr.globalEpoch.store(1'u64, moRelaxed)
    let scanning = scanStart(addr mgr).loadEpoch(epochsBeforeNeutralize = 2)
    check scanning.threshold == 0'u64

  test "threshold calculation with high epoch":
    mgr.globalEpoch.store(10'u64, moRelaxed)
    let scanning = scanStart(addr mgr).loadEpoch(epochsBeforeNeutralize = 2)
    check scanning.threshold == 8'u64
