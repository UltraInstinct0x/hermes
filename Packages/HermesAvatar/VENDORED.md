# HermesAvatar (vendored)

A copy of the Swift port in the private `UltraInstinct0x/hermes-avatar` repository (`swift/` plus `golden/`).
The app copies it instead of using a submodule, so the app builds without access to that repository.

- Source: hermes-avatar, commit recorded in `SOURCE_COMMIT`.
- Engine derived from bloub by Jérémy Perret (MIT); see `NOTICE` and `LICENSE`.
- `golden/` is the TypeScript engine's output. `swift test` here checks the Swift port against it; the desktop's
  vendored TypeScript copy (`src/vendor/hermes-avatar`) is checked against the same files by
  `src/vendor/hermes-avatar/golden.test.ts`.

To update: change hermes-avatar first, then copy `swift/` and `golden/` here and `ts/src/` to `src/vendor/hermes-avatar/`.
