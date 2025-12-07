# API Reference

Auto-generated API documentation from source code.

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
