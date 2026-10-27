import unittest
import debra

suite "debra":
  test "hello returns expected greeting":
    check hello() == "hello from debra"

  test "version present":
    check projectVersion == "0.0.1"
