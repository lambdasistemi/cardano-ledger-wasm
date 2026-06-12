# 001 — Bootstrap `cardano-ledger-wasm` (W0)

Part of epic [#84](https://github.com/lambdasistemi/cardano-ledger-inspector/issues/84)
(extract `cardano-ledger-wasm`). This ticket is
[W0 / #85](https://github.com/lambdasistemi/cardano-ledger-inspector/issues/85).

## Goal

Stand up a new public repository `lambdasistemi/cardano-ledger-wasm` with an
**empty-but-buildable skeleton on the wasm toolchain**. No ledger code yet —
that is W1. This proves the `ghc-wasm-meta` + `wasi-sdk` + CHaP + wasm-Plutus
fork toolchain end-to-end before the real kernel lift.

## User stories

- As the W1 implementer, I can `git clone` the repo and `nix build` to get a
  `wasm32-wasi` artifact from a trivial stub, so I know the toolchain works
  before I move the ledger kernel in.
- As a contributor, `nix develop -c just dev-build` builds the stub inside the
  dev shell, so the wasm dev loop is proven usable (the mandatory nix-develop
  gate).
- As a maintainer, CI is green on every PR, the release pipeline validates, and
  `main` is protected.

## Functional requirements

1. **Repo** `lambdasistemi/cardano-ledger-wasm`, public, default branch `main`,
   MIT license, labels `feat`/`fix`/`docs`/`chore`/`refactor`/`test`/`ci`/
   `experiment`, bootstrap PR assigned to `paolino`.
2. **Flake** mirroring the wasm toolchain of `cardano-ledger-inspector`:
   - inputs: `haskell.nix`, `hackage.nix`, `CHaP`, `ghc-wasm-meta`,
     `iohk-nix`, `flake-parts` (same revs as the inspector flake at the time
     of bootstrap).
   - `ghcWasmMeta = ghc-wasm-meta.packages.<sys>.all_9_12`,
     `wasiSdk = ghc-wasm-meta.packages.<sys>.wasi-sdk`.
   - the vendored `nix/wasm/` toolchain (`default.nix`,
     `mkCardanoLedgerWasm.nix`, `cabal-project-fragment.nix`, `forks.json`,
     `c-libs/`) carrying the full fork pin set, **including the wasm-Plutus
     fork** (`forks.json` `plutus` pin → `intersectmbo/plutus` rev, the
     `1.65.0.0-wasm32.1` wasm32 fork), so W1 only flips `withCLibs` and adds
     the ledger closure.
3. **Stub package** `cardano-ledger-wasm`: a trivial library + executable that
   builds to `wasm32-wasi`. Shape mirrors the inspector's `wasm-smoke` target
   (cborg-only — exercises a CHaP/fork fetch without pulling the ledger
   closure). `nix build` (default package) yields `cardano-ledger-wasm.wasm`.
4. **CI** on `nixos` self-hosted runner:
   - `Build Gate` — `nix build` of the stub + `nix flake check`.
   - `Dev shell` — **mandatory** `nix develop -c just dev-build` (wasm cabal
     build inside the shell).
   - `Format (fourmolu)` and `Hlint`.
5. **Release** — release-please **manifest mode** + `sync-cabal-version` drift
   guard (per `haskell-release-workflow`): `release-please-config.json`,
   `.release-please-manifest.json`, `release.yml`, `sync-cabal-version.yml`,
   and a CI step asserting the `.cabal` version equals the PVP-normalized
   manifest version.
6. **Branch protection** on `main`: required checks `Build Gate`, `Dev shell`,
   `Format (fourmolu)`, `Hlint`; admin bypass.

## Acceptance criteria

- [ ] `nix build` produces a `wasm32-wasi` artifact from the stub.
- [ ] `nix flake check` passes.
- [ ] `nix develop -c just dev-build` builds the stub (the nix-develop gate).
- [ ] CI green on the bootstrap PR including the `Dev shell` job.
- [ ] release-please config validates (`jq`/schema) and the drift guard works.
- [ ] `main` protected with the four required checks.
- [ ] Repo public; labels present; bootstrap PR assigned to `paolino`.

## Out of scope (W1+)

- Any ledger / Plutus kernel code, `withCLibs = true` builds, the real
  decoder, docs site / GitHub Pages, release artifact publication (the release
  pipeline only needs to *validate*, not publish, for W0).

## Non-functional

- Bisect-safe commits, Conventional Commits + `Tasks:` trailer.
- Hackage-ready stub cabal (`cabal check` clean); fourmolu 70-col leading-comma
  style; haddock on exports.
- Supply-chain: fork pins are nix32 hashes in `forks.json` (SRI triggers
  fetchgit FOD store-path scan failures — see the `nix` skill).
