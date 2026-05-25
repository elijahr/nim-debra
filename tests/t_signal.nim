# tests/t_signal.nim

import unittest2

import std/posix

import debra/atomics
import debra/constants
import debra/limbo
import debra/signal
import debra/thread_id
import debra/types

suite "Signal Handler":
  test "installSignalHandler is idempotent":
    # Should not crash when called multiple times
    installSignalHandler()
    installSignalHandler()
    check true

  test "isSignalHandlerInstalled returns true after install":
    installSignalHandler()
    check isSignalHandlerInstalled() == true

  test "handler mutates correct thread slot without corrupting siblings":
    ## Regression test for the threadStateSize/headerSize stride bug.
    ##
    ## When the signal handler walks `DebraManager.threads[]` using
    ## hard-coded constants that disagree with the real `ThreadState[N]`
    ## layout, the handler writes pinned/neutralized into the wrong
    ## slot. With `threadStateSize = 32` (the buggy value) and the real
    ## struct size of 64 bytes (post-currentBag/limboBagTail), invoking
    ## the handler for `threadLocalIdx = 1` aims at byte offset
    ## `128 + 1 * 32 = 160`. That address lands inside thread 0's slot
    ## (thread 0 spans bytes 128..191), specifically at thread 0's
    ## `currentBag` pointer. The bug therefore (a) corrupts thread 0's
    ## limbo bag pointers and (b) leaves thread 1's pinned/neutralized
    ## flags untouched. This test asserts both halves.

    # Use 4 thread slots so we exercise a non-zero index.
    var mgr: DebraManager[4, ccSingle]
    mgr.globalEpoch.store(1'u64, moRelaxed)
    mgr.activeThreadMask.store(0'u64, moRelaxed)
    for i in 0 ..< 4:
      mgr.threads[i].epoch.store(0'u64, moRelaxed)
      mgr.threads[i].pinned.store(false, moRelaxed)
      mgr.threads[i].neutralized.store(false, moRelaxed)
      mgr.threads[i].threadId.store(InvalidThreadId, moRelaxed)
      mgr.threads[i].currentBag = nil
      mgr.threads[i].limboBagTail = nil

    # Install sentinel pointers in thread 0's limbo-bag slots. The low
    # byte of each sentinel is non-zero so the buggy handler's
    # `pinnedPtr[].load(moAcquire)` (which actually reads the low byte
    # of thread 0's `currentBag`) returns true and the buggy code path
    # writes through `pinnedPtr` and `neutralizedPtr` -- corrupting
    # thread 0.
    let sentinelCurrentBag = cast[ptr LimboBag](0xDEADBEEFCAFEBABE'u64)
    let sentinelLimboTail = cast[ptr LimboBag](0xFEEDFACE12345678'u64)
    mgr.threads[0].currentBag = sentinelCurrentBag
    mgr.threads[0].limboBagTail = sentinelLimboTail

    # Mark thread 1 as pinned. After the handler runs against thread 1,
    # this should be cleared and `neutralized` should be set.
    mgr.threads[1].pinned.store(true, moRelaxed)
    mgr.threads[1].neutralized.store(false, moRelaxed)

    # Tell the signal handler "this thread is registered as slot 1 of
    # `mgr`". The handler is keyed off these threadvars + the global
    # manager pointer.
    installSignalHandler()
    setGlobalManager(addr mgr)
    threadLocalIdx = 1
    threadLocalRegistered = true

    # Block other signals briefly and deliver SIGUSR1 to ourselves so
    # the handler runs synchronously on this thread before
    # `pthread_kill` returns.
    let killRc = pthread_kill(pthread_self(), QuiescentSignal)

    # Tear down the threadvars promptly so a stray later signal can't
    # trip on partial state.
    threadLocalRegistered = false
    threadLocalIdx = 0
    setGlobalManager(cast[pointer](nil))

    # Capture the post-handler state of every field we care about
    # BEFORE leaving the test scope. The DebraManager `=destroy` walks
    # `limboBagTail.next` and would crash on the corrupted-pointer path
    # under the bug, masking our assertions; capturing first lets us
    # then null the pointers out and let `=destroy` succeed regardless.
    let observedKillRc = killRc
    let observedThread0CurrentBag = mgr.threads[0].currentBag
    let observedThread0LimboTail = mgr.threads[0].limboBagTail
    let observedThread0Pinned = mgr.threads[0].pinned.load(moRelaxed)
    let observedThread0Neutralized = mgr.threads[0].neutralized.load(moRelaxed)
    let observedThread0Epoch = mgr.threads[0].epoch.load(moRelaxed)
    let observedThread1Pinned = mgr.threads[1].pinned.load(moRelaxed)
    let observedThread1Neutralized = mgr.threads[1].neutralized.load(moRelaxed)

    # Now defuse the sentinels so `=destroy` can run cleanly even if
    # they were corrupted into bogus addresses.
    for i in 0 ..< 4:
      mgr.threads[i].currentBag = nil
      mgr.threads[i].limboBagTail = nil

    check observedKillRc == 0

    # The handler must have flipped slot 1's flags...
    check observedThread1Pinned == false
    check observedThread1Neutralized == true

    # ...and must NOT have touched thread 0's limbo bag pointers.
    check observedThread0CurrentBag == sentinelCurrentBag
    check observedThread0LimboTail == sentinelLimboTail

    # And thread 0's pinned/neutralized/epoch are still untouched.
    check observedThread0Pinned == false
    check observedThread0Neutralized == false
    check observedThread0Epoch == 0'u64
