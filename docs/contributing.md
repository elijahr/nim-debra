# Contributing

Contributions are welcome! This document outlines how to contribute to nim-debra.

## Development Setup

1. Clone the repository:
```bash
git clone https://github.com/elijahr/nim-debra.git
cd nim-debra
```

2. Install dependencies:
```bash
nimble install -d
```

3. Run tests:
```bash
nimble test
```

## Testing

All changes should include tests. The test suite is located in `tests/`:

- Unit tests for individual typestates in `tests/t_*.nim`
- Integration tests in `tests/t_integration.nim`
- Main test runner in `tests/test.nim`

Run tests with:
```bash
nimble test
```

## Code Style

- Follow standard Nim style conventions
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and single-purpose

## Typestate Design

When adding or modifying typestates:

1. Define states as `distinct` types wrapping a context object
2. Use `typestate` block to declare valid transitions
3. Mark transition functions with `{.transition.}` pragma
4. Write tests that verify both valid and invalid transitions

Example:
```nim
type
  Context = object
    data: int
  StateA = distinct Context
  StateB = distinct Context

typestate Context:
  states StateA, StateB
  transitions:
    StateA -> StateB

proc transition(a: StateA): StateB {.transition.} =
  StateB(a.Context)
```

## Documentation

- Add docstrings to all public procs and types
- Update relevant guide pages in `docs/guide/`
- Run `mkdocs serve` to preview documentation locally

## Pull Requests

1. Create a feature branch from `main`
2. Make your changes with clear commit messages
3. Add tests for new functionality
4. Update documentation as needed
5. Submit a pull request

## Questions?

Open an issue on GitHub or start a discussion.
