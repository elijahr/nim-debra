## Cardinality axis for the typestate surface (introduced in 0.8.0).
##
## `PinScopeCardinality` is the second generic-parameter axis (the **CC**
## axis) that nim-debra threads through `DebraManager`, `ThreadHandle`,
## and the EBR typestate graphs. It exposes consumer-cardinality at the
## type level so downstream lock-free data structures can statically gate
## single-writer atomic primitives (`retireOnPublish`) from
## CAS-based primitives (`retireOnCAS`).
##
## Values:
##
## * `ccSingle` - single consumer / no retire-race. **Default** for every
##   call shape in 0.7.x-compat code. Used for producer-side pins and
##   true single-consumer queue contexts.
## * `ccMulti` - multi-consumer / retire-race possible. Required for
##   consumer pins on multi-consumer queues.
##
## The CC parameter defaults to `ccSingle` everywhere Nim's `static`
## defaulting reaches, so existing 0.7.x callers compile unchanged.

type PinScopeCardinality* = enum
  ccSingle
  ccMulti
