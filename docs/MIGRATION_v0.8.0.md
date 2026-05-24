# Migration Guide: nim-debra 0.8.0

## Audience

Users with code calling `withPin(handle): body` (anonymous form) or
`withPin(handle, named): body` (named-overload form). `withPin` is
deprecated in 0.8.0 and targeted for removal in 0.9.0; new code should
use `PinnedScope`.

If your code does not call `withPin` and you do not annotate
`ThreadHandle`/`Pinned`/`Unpinned`/`Retired`/`Neutralized`/`Registered`/
`DebraManager`/`RetireReady`/`PinnedScope` types explicitly, the
0.7.x → 0.8.0 upgrade should be source-compatible thanks to the
`ccSingle` default on the new `CC` generic parameter.

## Mechanical translation

### Anonymous form (`withPin(handle): body`)

```nim
# Before (0.7.x):
withPin(handle):
  # body referencing `it: Pinned[N]`
  let r = retire(it, ptr, dtor)

# After (0.8.0):
block:
  var scope = pinScope(unpinned(handle))
  var ready = retireReady(scope.state)
  discard ready.retire(ptr, dtor)
  # =destroy auto-runs unpin + close at block exit
```

Key changes:

- `withPin` is replaced by `pinScope(unpinned(handle))`, which returns a
  `PinnedScope[N, ccSingle]` value bound to `scope`.
- The implicit `it` binding is replaced by `scope.state` (a `Pinned[N]`
  on the pinned axis).
- `retire` is reached through the explicit `retireReady` chain rather
  than as a free proc on `it`.
- Unpin and close happen automatically via `=destroy` when `scope` goes
  out of scope, including on early-return and exception paths. No
  explicit cleanup is required.

### Named-overload form (`withPin(handle, named): body`)

```nim
# Before (0.7.x):
withPin(handle, myPin):
  # body referencing `myPin: Pinned[N]`
  let r = retire(myPin, ptr, dtor)

# After (0.8.0):
block:
  var myPin = pinScope(unpinned(handle))
  var ready = retireReady(myPin.state)
  discard ready.retire(ptr, dtor)
  # =destroy auto-runs unpin + close at block exit
```

The named binding becomes the `PinnedScope` value itself; reach the
underlying `Pinned[N]` via `myPin.state`.

## Cardinality opt-in (`PinScopeCardinality`)

0.8.0 introduces the `PinScopeCardinality` enum on the second generic
parameter (`CC`) of nine typestate-axis types:

- `ccSingle` (**default, safe**): single `PinnedScope` per thread per
  lifetime. The compiler enforces single-pin discipline; the runtime
  invariants match the 0.7.x single-`withPin`-at-a-time model.
- `ccMulti` (**opt-in, advanced**): multi-pin patterns are permitted on
  this axis. Selected explicitly via `[N, ccMulti]` on the type
  annotation.

### Foot-gun callout for `ccMulti`

`ccMulti` is **not** "use this if you're not sure." It is an explicit
opt-in for advanced patterns. When you opt in, you take on:

- Explicit reasoning about pin ordering — nested `PinnedScope` lifetimes
  must form a stack, not an arbitrary DAG, or you risk reading from a
  retired bag.
- Explicit reasoning about limbo-bag advancement — concurrent multi-pin
  scopes can stall epoch advancement if their lifetimes overlap with
  the manager's advance protocol in unexpected ways.

`ccSingle` is the right default. Reach for `ccMulti` only when you have
a concrete pattern that demands it and you have audited the pin
ordering and advance interaction.

## AdvanceContext

**No migration needed.** `AdvanceContext` gained the `CC` parameter — its
field must accept a `ptr DebraManager[MT, CC]` for both cardinalities — but
the epoch advancement protocol itself is cardinality-uniform: pure atomic
arithmetic with no cardinality-dependent branching. Because `CC` defaults to
`ccSingle`, existing annotations on `AdvanceContext` values do not need to be
updated; `ccMulti` managers flow through automatically when constructed via
`initDebraManager[N, ccMulti]()`.

## Deprecation timeline

| Version | `withPin` status |
| ------- | ---------------- |
| 0.8.0   | Deprecated, still works, emits deprecation warning. |
| 0.9.0   | Planned removal. New code MUST use `PinnedScope`. |

There is no flag to silence the deprecation warning in 0.8.0; the
intent is to make the migration visible at every call site so the
0.9.0 removal is a no-op for downstream code.

## Self-evidence

nim-debra 0.8.0 itself migrated 17 internal `withPin` call sites to
`PinnedScope` across the source tree, plus 60+ DR-T6 explicit-annotation
sites widened to spell the `CC` second parameter. This is the same
translation the migration guide prescribes — proof the pattern works
end-to-end and is exercised by the 242-test suite across all five
backends (orc, arc, atomicArc, refc, cpp).
