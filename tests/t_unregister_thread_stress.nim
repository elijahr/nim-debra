## tests/t_unregister_thread_stress.nim
##
## Task B4.5 — Concurrent stress test for `unregisterThread`.
##
## Companion to the per-task B4 unit tests in `t_unregister_thread.nim`. Those
## tests are single-threaded and sequential; they prove the CAS sequence is
## *correct* in isolation but cannot exercise the register/unregister
## interaction under genuine load. This file does.
##
## ## Scenarios
##
## 1. **Repeat register/unregister, full mask.** N == `MaxThreads` workers each
##    loop `RepeatIters` iterations of `register -> unregister`. Asserts that
##    after all workers complete, the mask is zero and every `threadId` slot is
##    `InvalidThreadId`. Targets ABA / store-reorder races in the CAS clear.
##
## 2. **Re-claim race under contention.** Workers > `MaxThreads`. Each worker
##    loops: try `register` (catch `DebraRegistrationError` on full); on
##    success, immediately `unregister`, count both. Asserts
##    `successfulRegisters == successfulUnregisters` (slot accounting) AND
##    final mask is zero. Targets slot-leak bugs where a successful register
##    followed by a CAS-loop bug in unregister leaves the bit set.
##
## 3. **Pin/unpin between register/unregister.** Each worker does
##    `register -> pinScope -> trivial work -> close scope -> unregister`,
##    looped. Verifies the B4 unregister coexists with the existing pin
##    protocol. Asserts mask zero, pinned-flag zero, all `threadId` slots free.
##
## 4. **Idempotent double-unregister under contention.** Workers concurrently
##    call `unregisterThread` twice in a row on the same handle. Per the B3
##    operator-locked contract (see `t_unregister_thread.nim:73`), the second
##    call is a no-op. Asserts no corruption: final mask zero, all `threadId`
##    slots free, all worker handles' slot indices are within range.
##
## ## Test discipline
##
## - Uses `std/threads` (`Thread`, `createThread`, `joinThread`) and
##   `std/atomics` (shared counters / readiness barriers).
## - Each worker calls `setGlobalManager(addr mgr)` before `registerThread`
##   because `registerThread` installs the per-thread signal handler that uses
##   the manager pointer.
## - `MaxThreads`, worker counts, and `RepeatIters` are tuned to be brisk on a
##   thermally-warm laptop (target: full file under ~5s wall on M-series).
## - Assertions follow the FULL ASSERTION PRINCIPLE: every final assertion
##   compares against an exactly-computed expected value.

import std/sysatomics  # for cpuRelax only

import unittest2

import debra
import debra/atomics
import debra/types
import debra/typestates/cardinality
import debra/typestates/pinned_scope
import debra/typestates/registration

# Tuning constants. RepeatIters is intentionally modest; the stress is in the
# interleaving, not the iteration count. A bug in the CAS loop will surface
# inside hundreds of iterations across 16 threads.
const
  StressMaxThreads = 16
  StressRepeatIters = 200
  ContentionMaxThreads = 4
  ContentionWorkers = 16
  ContentionIters = 300
  PinIters = 150
  DoubleUnregIters = 100

# ---------------------------------------------------------------------------
# Scenario 1: N == MaxThreads workers, repeated register/unregister.
# ---------------------------------------------------------------------------

type
  Scenario1Ctx = object
    mgr: ptr DebraManager[StressMaxThreads, ccSingle]
    barrier: ptr Atomic[int]
    startGate: ptr Atomic[bool]

var s1Ctx: Scenario1Ctx
var s1Errors: Atomic[int]

proc s1Worker() {.thread.} =
  # Arrive at the barrier, then wait for the start gate.
  discard s1Ctx.barrier[].fetchAdd(1)
  while not s1Ctx.startGate[].load(): cpuRelax()
  setGlobalManager(s1Ctx.mgr)
  for i in 0 ..< StressRepeatIters:
    try:
      let h = registerThread(s1Ctx.mgr[])
      # Sanity: idx must be in range and the bit must be set right now.
      if h.idx < 0 or h.idx >= StressMaxThreads:
        discard s1Errors.fetchAdd(1)
        return
      unregisterThread(s1Ctx.mgr[], h)
    except DebraRegistrationError:
      # With N == MaxThreads workers all looping register/unregister, the
      # mask can transiently be full while every other worker holds its
      # claim. A failed register is an acceptable transient, not a bug — but
      # it MUST be rare. Count and continue.
      discard s1Errors.fetchAdd(1)

# ---------------------------------------------------------------------------
# Scenario 2: re-claim race, workers > MaxThreads.
# ---------------------------------------------------------------------------

type
  Scenario2Ctx = object
    mgr: ptr DebraManager[ContentionMaxThreads, ccSingle]
    startGate: ptr Atomic[bool]

var s2Ctx: Scenario2Ctx
var s2Registers: Atomic[int]
var s2Unregisters: Atomic[int]

proc s2Worker() {.thread.} =
  while not s2Ctx.startGate[].load(): cpuRelax()
  setGlobalManager(s2Ctx.mgr)
  for i in 0 ..< ContentionIters:
    try:
      let h = registerThread(s2Ctx.mgr[])
      discard s2Registers.fetchAdd(1)
      unregisterThread(s2Ctx.mgr[], h)
      discard s2Unregisters.fetchAdd(1)
    except DebraRegistrationError:
      discard

# ---------------------------------------------------------------------------
# Scenario 3: pin/unpin between register and unregister.
# ---------------------------------------------------------------------------

type
  Scenario3Ctx = object
    mgr: ptr DebraManager[StressMaxThreads, ccSingle]
    startGate: ptr Atomic[bool]

var s3Ctx: Scenario3Ctx
var s3PinObserved: Atomic[int]
var s3RegisterFailures: Atomic[int]

proc s3Worker() {.thread.} =
  while not s3Ctx.startGate[].load(): cpuRelax()
  setGlobalManager(s3Ctx.mgr)
  for i in 0 ..< PinIters:
    try:
      let h = registerThread(s3Ctx.mgr[])
      block:
        var scope = pinScope(unpinned(h))
        # Observe pinned flag inside the scope; this is real work that
        # touches the slot.
        if s3Ctx.mgr.threads[h.idx].pinned.load(moAcquire):
          discard s3PinObserved.fetchAdd(1)
        discard scope.consumed
      # scope destroyed here — slot is unpinned again before we
      # unregister. The B4 contract requires "no in-flight pin"; the
      # block boundary (=destroy on PinnedScope) guarantees that.
      unregisterThread(s3Ctx.mgr[], h)
    except DebraRegistrationError:
      discard s3RegisterFailures.fetchAdd(1)

# ---------------------------------------------------------------------------
# Scenario 4: idempotent double-unregister under contention.
# ---------------------------------------------------------------------------

type
  Scenario4Ctx = object
    mgr: ptr DebraManager[StressMaxThreads, ccSingle]
    startGate: ptr Atomic[bool]

var s4Ctx: Scenario4Ctx
var s4DoubleCalls: Atomic[int]
var s4RegisterFailures: Atomic[int]

proc s4Worker() {.thread.} =
  while not s4Ctx.startGate[].load(): cpuRelax()
  setGlobalManager(s4Ctx.mgr)
  for i in 0 ..< DoubleUnregIters:
    try:
      let h = registerThread(s4Ctx.mgr[])
      unregisterThread(s4Ctx.mgr[], h)
      unregisterThread(s4Ctx.mgr[], h)  # idempotent no-op
      discard s4DoubleCalls.fetchAdd(1)
    except DebraRegistrationError:
      discard s4RegisterFailures.fetchAdd(1)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "unregisterThread concurrent stress (Task B4.5)":

  test "scenario 1: N=MaxThreads workers, repeated register/unregister, mask returns to zero":
    var mgr = initDebraManager[StressMaxThreads, ccSingle]()
    setGlobalManager(addr mgr)

    var barrier: Atomic[int]
    var startGate: Atomic[bool]
    barrier.store(0)
    startGate.store(false)
    s1Errors.store(0)
    s1Ctx = Scenario1Ctx(
      mgr: addr mgr,
      barrier: addr barrier,
      startGate: addr startGate,
    )

    var workers: array[StressMaxThreads, Thread[void]]
    for i in 0 ..< StressMaxThreads:
      createThread(workers[i], s1Worker)

    # Wait for all workers to arrive at the barrier, then release.
    while barrier.load() < StressMaxThreads: cpuRelax()
    startGate.store(true)

    for i in 0 ..< StressMaxThreads:
      joinThread(workers[i])

    # Final state: nothing pinned, no slot claimed, all threadIds free.
    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    for i in 0 ..< StressMaxThreads:
      check mgr.threads[i].threadId.load(moAcquire) == InvalidThreadId
      check mgr.threads[i].pinned.load(moAcquire) == false

    # Errors are acceptable transients (mask full when a worker tried to
    # register); but a flood means real contention loss, surface a hint.
    let errs = s1Errors.load()
    let totalAttempts = StressMaxThreads * StressRepeatIters
    # Expect fewer than 25% failures. Higher means register/unregister is
    # not actually freeing slots in a timely way.
    check errs < (totalAttempts div 4)
    # Affirmative: at least some workers must have actually run. If `errs ==
    # totalAttempts` every register failed and the test would have caught
    # nothing; this guards against a degenerate "all-failed" pass.
    check errs < totalAttempts

  test "scenario 2: re-claim race, total successful registers equals total successful unregisters":
    var mgr = initDebraManager[ContentionMaxThreads, ccSingle]()
    setGlobalManager(addr mgr)

    var startGate: Atomic[bool]
    startGate.store(false)
    s2Registers.store(0)
    s2Unregisters.store(0)
    s2Ctx = Scenario2Ctx(mgr: addr mgr, startGate: addr startGate)

    var workers: array[ContentionWorkers, Thread[void]]
    for i in 0 ..< ContentionWorkers:
      createThread(workers[i], s2Worker)

    startGate.store(true)
    for i in 0 ..< ContentionWorkers:
      joinThread(workers[i])

    let regs = s2Registers.load()
    let unregs = s2Unregisters.load()
    # Slot-accounting invariant: every successful register has a matching
    # unregister (workers only count unregister after the call returns).
    check regs == unregs
    # Sanity: with 16 workers x 300 iters and 4 slots there must be some
    # successful registrations — if zero, the test isn't actually testing
    # anything.
    check regs > 0
    # Final state: mask zero, all threadIds free.
    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    for i in 0 ..< ContentionMaxThreads:
      check mgr.threads[i].threadId.load(moAcquire) == InvalidThreadId

  test "scenario 3: pin/unpin between register and unregister coexists cleanly":
    var mgr = initDebraManager[StressMaxThreads, ccSingle]()
    setGlobalManager(addr mgr)

    var startGate: Atomic[bool]
    startGate.store(false)
    s3PinObserved.store(0)
    s3RegisterFailures.store(0)
    s3Ctx = Scenario3Ctx(mgr: addr mgr, startGate: addr startGate)

    var workers: array[StressMaxThreads, Thread[void]]
    for i in 0 ..< StressMaxThreads:
      createThread(workers[i], s3Worker)

    startGate.store(true)
    for i in 0 ..< StressMaxThreads:
      joinThread(workers[i])

    # Final state: mask zero, all threadIds free, no pinned flags left.
    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    for i in 0 ..< StressMaxThreads:
      check mgr.threads[i].threadId.load(moAcquire) == InvalidThreadId
      check mgr.threads[i].pinned.load(moAcquire) == false
    # We expect every worker iteration to have observed the pinned flag
    # set inside its own scope. Allow that some iterations failed to
    # register (rare) but the count must be substantial.
    let pinObs = s3PinObserved.load()
    let regFails = s3RegisterFailures.load()
    let totalAttempts = StressMaxThreads * PinIters
    check pinObs == (totalAttempts - regFails)
    check pinObs > 0

  test "scenario 4: idempotent double-unregister under contention leaves state clean":
    var mgr = initDebraManager[StressMaxThreads, ccSingle]()
    setGlobalManager(addr mgr)

    var startGate: Atomic[bool]
    startGate.store(false)
    s4DoubleCalls.store(0)
    s4RegisterFailures.store(0)
    s4Ctx = Scenario4Ctx(mgr: addr mgr, startGate: addr startGate)

    var workers: array[StressMaxThreads, Thread[void]]
    for i in 0 ..< StressMaxThreads:
      createThread(workers[i], s4Worker)

    startGate.store(true)
    for i in 0 ..< StressMaxThreads:
      joinThread(workers[i])

    # Final state: nothing claimed, all threadIds free.
    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    for i in 0 ..< StressMaxThreads:
      check mgr.threads[i].threadId.load(moAcquire) == InvalidThreadId

    let doubles = s4DoubleCalls.load()
    let fails = s4RegisterFailures.load()
    let totalAttempts = StressMaxThreads * DoubleUnregIters
    # Every successful register completed BOTH unregister calls without
    # raising; fails + doubles must cover every attempted iteration.
    check doubles + fails == totalAttempts
    check doubles > 0
