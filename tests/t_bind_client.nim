import unittest2
import debra
import debra/atomics

import debra/types

suite "Client refcount (bindClient / unbindClient / clientCount)":
  test "newly initialized manager has zero clients":
    var mgr = initDebraManager[4]()
    check mgr.clientCount() == 0

  test "bindClient increments and unbindClient decrements":
    var mgr = initDebraManager[4]()
    mgr.bindClient()
    mgr.bindClient()
    check mgr.clientCount() == 2
    mgr.unbindClient()
    mgr.unbindClient()
    check mgr.clientCount() == 0

  test "destructor fires when clients are still bound":
    # The =destroy hook on DebraManager does a `doAssert
    # boundClients == 0`, which raises AssertionDefect (a Defect, not
    # a CatchableError). We exercise the assertion by leaking a
    # bind in a scope that goes out of scope inside a try/except
    # AssertionDefect block.
    var fired = false
    try:
      block:
        var mgr = initDebraManager[4]()
        mgr.bindClient()
        # Manager goes out of scope here with boundClients == 1.
    except AssertionDefect:
      fired = true
    check fired
