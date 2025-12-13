# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2025-12-12

### Added

- State machine diagrams for all typestate documentation
  - `guard.svg` - EpochGuard pin/unpin lifecycle
  - `retire.svg` - Object retirement flow
  - `reclaim.svg` - Reclamation process
  - `registration.svg` - Thread registration
  - `neutralize.svg` - Neutralization protocol
  - `advance.svg` - Epoch advancement
  - `slot.svg` - Thread slot management
  - `manager.svg` - Manager initialization
  - `signal_handler.svg` - Signal handler states
- Example typestate diagrams in integration guide
  - `item_processing.svg` - Item processing pipeline
  - `lockfree_stack.svg` - Lock-free stack states

## [0.1.1] - 2025-12-12

### Added

- Typestate composition examples demonstrating integration with custom typestates
  - `item_processing.nim`: Generic item lifecycle typestate (Unprocessed → Processing → Completed|Failed)
  - `lockfree_stack_typestates.nim`: Lock-free stack with Empty/NonEmpty states using DEBRA internally
- Comprehensive test coverage for typestate composition
  - `t_item_processing.nim`: 8 tests for item processing transitions
  - `t_lockfree_stack_typestates.nim`: 10 tests for lock-free stack operations
- Typestate Composition section in integration guide
- `testExamples` nimble task to compile and run all example files
- Status badges in README

### Changed

- `pop()` in lock-free stack now returns `Option[Unprocessed[T]]` instead of bare type
  - Properly handles race condition where another thread pops the last item
  - Eliminates need for potentially invalid `default(T)` placeholder
- Improved sink parameter usage in slot transitions for proper move semantics
- Enhanced documentation for neutralization handling and thread registration

### Fixed

- Example files now wrapped in procs to fix `=dup` lifetime issues with Nim's `when isMainModule`
- Removed `nim.cfg` from repo (was causing CI failures due to Atlas local paths)

## [0.1.0] - 2025-12-10

### Added
- Initial implementation of DEBRA+ algorithm
- Typestate-enforced API for correct operation sequencing
- DebraManager for coordinating epoch-based reclamation across threads
- Thread registration with ThreadHandle
- Pin/unpin operations with EpochGuard typestate
- Object retirement with limbo bags
- Reclamation of objects from safe epochs
- Signal-based neutralization for stalled threads
- ThreadSlot typestate for slot lifecycle management
- EpochAdvance typestate for epoch advancement
- ThreadId wrapper for cross-platform signal delivery
- Documentation site with MkDocs Material theme
- CI workflow for running tests on Linux
- Docs deployment workflow for GitHub Pages
- Integration tests

[Unreleased]: https://github.com/elijahr/nim-debra/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/elijahr/nim-debra/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/elijahr/nim-debra/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/elijahr/nim-debra/releases/tag/v0.1.0
