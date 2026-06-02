# API Reference

Auto-generated API documentation from source code.

For a high-level overview of the custom atomics module — including the
DWCAS (16-byte / 128-bit) surface introduced in v0.10.0 — see the
[Atomics guide](guide/atomics.md). The auto-extracted entries below
cover every public symbol; the guide covers the *why* and the worked
LCRQ example.

## Atomics

Custom atomics module with compile-time lock-free guarantees, per-op
memory-order validation, and DWCAS (16-byte / 128-bit) atomics via
`Atomic[Pair[A, B]]`. See [guide/atomics.md](guide/atomics.md) for the
narrative overview.

::: debra.atomics

---

## Main Module

::: debra

---

## Core Types

Type definitions for DEBRA+ manager and thread state.

::: debra.types

---

## Constants

Configuration constants for DEBRA+ algorithm.

::: debra.constants

---

## Limbo Bags

Data structures for thread-local retire queues.

::: debra.limbo

---

## Signal Handling

POSIX signal handling for neutralization protocol.

::: debra.signal

---

## Typestates

### Signal Handler

Signal handler installation lifecycle.

::: debra.typestates.signal_handler

---

### Manager

Manager initialization and shutdown lifecycle.

::: debra.typestates.manager

---

### Registration

Thread registration lifecycle.

::: debra.typestates.registration

---

### Thread Slot

Thread slot allocation and release.

::: debra.typestates.slot

---

### Epoch Guard

Pin/unpin critical section lifecycle.

::: debra.typestates.guard

---

### Retire

Object retirement to limbo bags.

::: debra.typestates.retire

---

### Reclamation

Safe memory reclamation from limbo bags.

::: debra.typestates.reclaim

---

### Neutralization

Thread neutralization protocol.

::: debra.typestates.neutralize

---

### Epoch Advance

Global epoch advancement.

::: debra.typestates.advance
