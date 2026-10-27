# debra - Zero-overhead compatibility facade for lockfree/smr/nebr (Safe Memory Reclamation)

const projectVersion* = "0.0.1"

const greetingMsg* = "hello from debra"

proc hello*(): string =
  ## Returns standard project greeting string.
  greetingMsg

proc add*(a, b: int): int =
  ## Adds two integers.
  a + b
