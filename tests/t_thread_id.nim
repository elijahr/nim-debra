# tests/t_thread_id.nim

import unittest2

import debra/thread_id

# Work around macOS pthread_t stringify issue by defining a simple converter
# This prevents Nim from auto-generating an invalid $ operator for Pthread
proc `$`*(tid: ThreadId): string =
  if tid.isValid(): "ThreadId(valid)" else: "ThreadId(invalid)"

suite "ThreadId":
  test "currentThreadId returns valid thread ID":
    let tid = currentThreadId()
    check tid.isValid()

  test "currentThreadId is consistent within same thread":
    let tid1 = currentThreadId()
    let tid2 = currentThreadId()
    check tid1 == tid2

  test "equality operator works correctly":
    let tid1 = currentThreadId()
    let tid2 = currentThreadId()
    check tid1 == tid2

  test "different ThreadIds are not equal":
    let tid1 = unsafeThreadIdFromInt(1)
    let tid2 = unsafeThreadIdFromInt(2)
    check tid1 != tid2

  test "isValid returns true for valid thread ID":
    let tid = currentThreadId()
    check tid.isValid() == true

  test "isValid returns false for invalid thread ID":
    let tid = unsafeThreadIdFromInt(0)
    check tid.isValid() == false

  test "InvalidThreadId constant is not valid":
    check InvalidThreadId.isValid() == false

  test "InvalidThreadId has zero handle":
    check InvalidThreadId == unsafeThreadIdFromInt(0)

  test "sendSignal with signal 0 checks thread existence":
    # Signal 0 is a null signal that just checks if the thread exists
    # without actually sending a signal
    let tid = currentThreadId()
    let rc = tid.sendSignal(0)
    # Should return 0 (success) for the current thread
    check rc == 0

  test "sendSignal to invalid thread returns error":
    # Sending a signal to an invalid/non-existent thread should fail
    let invalidTid = unsafeThreadIdFromInt(999999)
    let rc = invalidTid.sendSignal(0)
    # Should return non-zero error code (typically ESRCH - No such process)
    check rc != 0

  test "unsafeThreadIdFromInt creates ThreadId from integer":
    let tid = unsafeThreadIdFromInt(12345)
    # Should create a ThreadId, though it may not be valid as an actual thread
    check tid.isValid() # Any non-zero value is considered "valid" in structure

  test "unsafeThreadIdFromInt with zero creates invalid ThreadId":
    let tid = unsafeThreadIdFromInt(0)
    check tid.isValid() == false
    check tid == InvalidThreadId
