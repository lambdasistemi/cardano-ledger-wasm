# cardano-ledger-wasm — Constitution

The principles that gate every plan and PR in this repository.

## Core principles

1. **wasm32-wasi is the target.** The product is Cardano ledger operations
   compiled to `wasm32-wasi`. The native/host path exists only to serve the
   wasm build (toolchain, tests, codegen). A change that only makes sense for a
   native binary is out of scope.
2. **Nix is the build gate.** `nix build`, `nix flake check`, and the
   **mandatory `nix develop -c just dev-build`** dev-shell build are the source
   of truth. `cabal build` outside `nix develop` is not a gate. Packaged checks
   never enter `nix develop`, so the dev shell has its own CI job.
3. **Vendored toolchain, single-file pin bumps.** The wasm toolchain
   (`nix/wasm/`) and its fork pins (`nix/wasm/forks.json`) are vendored here.
   Pins are nix32 hashes (SRI triggers fetchgit FOD store-path scan failures).
   A pin bump is a single-file, reviewable change.
4. **Bisect-safe, vertical commits.** Every commit compiles/builds. Conventional
   Commits + a `Tasks:` trailer linking to `specs/<NNN>/tasks.md` for
   behavior-changing commits. One reviewed commit per slice.
5. **Hackage-ready Haskell.** Cabal packages pass `cabal check`. Fourmolu
   70-column leading-comma style; haddock on all exports; module headers.
6. **Manifest-driven releases.** The `.release-please-manifest.json` version is
   authoritative; `sync-cabal-version` propagates it to the `.cabal` (PVP `.0`),
   and CI fails on drift. Merging the release PR tags; nothing publishes
   implicitly.

## Constraints

- Avoid `cardano-api`; the low-level seam is `cardano-ledger-*` /
  `cardano-ledger-binary`.
- No breaking change to the `lib.wasm.mkCardanoLedgerWasm` public surface
  without a spec.
- Self-hosted `nixos` runners for CI; cachix cache `paolino`.

## Workflow

- Issue-backed PRs; linear history; `main` protected with required checks
  (`Build Gate`, `Dev shell`, `Format (fourmolu)`, `Hlint`).
- Spec → plan → tasks before code (`specs/<NNN>-<slug>/`).
- Local CI (`nix develop -c just ci`) must be green before push; CI is not used
  to discover our own errors.

## Governance

This constitution gates planning. Amendments are PRs that update this file with
rationale.
