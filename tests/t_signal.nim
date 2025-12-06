# tests/t_signal.nim

import unittest2

import debra/signal

suite "Signal Handler":
  test "installSignalHandler is idempotent":
    # Should not crash when called multiple times
    installSignalHandler()
    installSignalHandler()
    check true

  test "isSignalHandlerInstalled returns true after install":
    installSignalHandler()
    check isSignalHandlerInstalled() == true
