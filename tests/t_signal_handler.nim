import unittest2

import debra/signal as realSignal
import debra/typestates/signal_handler

suite "SignalHandler typestate":
  test "starts uninstalled":
    let h = initSignalHandler()
    check h is HandlerUninstalled

  test "install transitions to HandlerInstalled":
    let h = initSignalHandler()
    let installed = h.install()
    check installed is HandlerInstalled
    # `signal_handler.install` calls `sigaction` directly with a no-op
    # placeholder handler, which clobbers the real handler installed by
    # `debra/signal.installSignalHandler`. Restore the real handler so
    # downstream tests (e.g. `t_neutralize`'s cross-slot delivery test)
    # still receive SIGUSR1 correctly.
    realSignal.forceReinstallSignalHandler()
