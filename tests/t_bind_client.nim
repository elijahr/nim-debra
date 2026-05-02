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

  test "unbindClient underflow fires AssertionDefect":
    # An unbalanced unbindClient (no matching bindClient) must trip the
    # underflow assertion at the moment of the bug, rather than slip
    # through to be detected later by the manager destructor.
    var mgr = initDebraManager[4]()
    var fired = false
    try:
      mgr.unbindClient()
    except AssertionDefect:
      fired = true
    check fired
    # Restore the count so the manager destructor does not also fire
    # (boundClients went from 0 to -1; bring it back to 0).
    mgr.bindClient()

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
