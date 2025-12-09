# debra.nimble

# Package

version       = "0.1.0"
author        = "elijahr <elijahr+debra@gmail.com>"
description   = "DEBRA+ safe memory reclamation for lock-free data structures"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]

# Dependencies

requires "nim >= 2.0.0"
requires "typestates >= 0.2.1"

# Tasks

task test, "Run tests":
  exec "nim c -r --mm:refc --threads:on --path:src -d:testing tests/test.nim"
