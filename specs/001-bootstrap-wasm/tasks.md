# 001 — Tasks

Slices are dispatched to a **Codex driver + Claude navigator** pair. The
orchestrator owns the docs (this file, `spec.md`, `plan.md`), `gate.sh`, the
constitution, repo/admin setup, push, and PR metadata.

Lists referenced here are specified in [spec.md](./spec.md) and
[plan.md](./plan.md); slices implement against those owning docs.

## Orchestrator-owned (no driver)

- [ ] T001 Repo creation + GitHub admin (repo, labels, topics, actions perms,
  Cachix secret, branch ruleset, stub-CI bootstrap on `main`). *(done in
  bootstrap; tracked here for the audit)*
- [ ] T002 Add `gate.sh` (`chore: add gate.sh`) and these docs + constitution
  (`docs:`), open the draft PR assigned to `paolino`.
- [ ] T010 Per-slice review + push; finalization audit; drop `gate.sh`; mark
  ready; merge; verify acceptance.

## Slice S1 — scaffold the buildable wasm skeleton  (one `feat:` commit)

Owned files: `flake.nix`, `flake.lock`, `cabal.project`, `cabal-wasm.project`,
`cardano-ledger-wasm/**`, `nix/wasm/**`, `nix/wasm-targets.nix`, `justfile`,
`fourmolu.yaml`.

- [X] T003 Vendor `nix/wasm/{default,mkCardanoLedgerWasm,cabal-project-fragment}.nix`,
  `nix/wasm/forks.json`, `nix/wasm/c-libs/**` verbatim from the inspector.
- [X] T004 `flake.nix` mirroring inspector inputs/overlays (drop purescript/UI),
  exposing `lib.wasm`, `packages.cardano-ledger-wasm`, `packages.default`,
  `apps.format-check`, `apps.hlint`, `devShells.default` (wasm toolchain on PATH).
- [X] T005 Stub package `cardano-ledger-wasm/**` + `cabal-wasm.project` +
  `cabal.project`, mirroring the inspector `wasm-smoke` target (cborg-only).
- [X] T006 `nix/wasm-targets.nix` wiring `cardano-ledger-wasm` via
  `lib.wasm.mkCardanoLedgerWasm` (`srpForks=["cborg"]`, `withCLibs=false`);
  compute + lock `dependenciesHash`.
- [X] T007 `justfile` (`dev-build`, `build`, `flake-check`, `format`,
  `format-check`, `hlint`, `ci`) + `fourmolu.yaml`.
- [X] T008 Prove: `nix build` yields `cardano-ledger-wasm.wasm`,
  `nix flake check` green, `nix develop -c just dev-build` green,
  `nix run .#format-check` + `nix run .#hlint` green. `./gate.sh` passes.

Commit: `feat: buildable wasm32-wasi skeleton (flake, toolchain, stub)` /
`Tasks: T003, T004, T005, T006, T007, T008`.

## Slice S2 — CI workflow  (one `ci:` commit)

Owned files: `.github/workflows/ci.yml`.

- [X] T009 `ci.yml` on `nixos`: jobs `Build Gate` (nix build + flake check),
  `Dev shell` (`nix develop -c just dev-build`), `Format (fourmolu)`, `Hlint`;
  cachix-action@v17 name `paolino`; concurrency cancel-in-progress.

Commit: `ci: wasm build + flake check + nix-develop gate + lint` /
`Tasks: T009`.

## Slice S3 — release pipeline (manifest mode)  (one `ci:`/`feat:` commit)

Owned files: `release-please-config.json`, `.release-please-manifest.json`,
`.github/workflows/release.yml`, `.github/workflows/sync-cabal-version.yml`,
and the `ci.yml` version-drift step.

- [ ] T011 `release-please-config.json` + `.release-please-manifest.json`
  (manifest mode, `0.1.0`).
- [ ] T012 `release.yml` (release-please-action@v4, no publish for W0).
- [ ] T013 `sync-cabal-version.yml` (semver→PVP, guarded to `release-please--`).
- [ ] T014 CI "Cabal version matches manifest" drift step; verify with
  `jq`/`actionlint`.

Commit: `ci: release-please manifest mode + sync-cabal-version drift guard` /
`Tasks: T011, T012, T013, T014`.

## Finalization (orchestrator)

- [ ] T015 Finalization audit, drop `gate.sh`, mark ready, merge after CI green,
  confirm `main` protected + acceptance met. Emit `COMPLETE`.
