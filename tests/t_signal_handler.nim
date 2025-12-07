import unittest2

import debra/typestates/signal_handler

suite "SignalHandler typestate":
  test "starts uninstalled":
    let h = initSignalHandler()
    check h is HandlerUninstalled

  test "install transitions to HandlerInstalled":
    let h = initSignalHandler()
    let installed = h.install()
    check installed is HandlerInstalled
