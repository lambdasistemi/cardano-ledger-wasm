# Plan — W1 lift the ledger kernel

## Tech stack

- Haskell (GHC 9.12 wasm32-wasi via ghc-wasm-meta), cardano-ledger (CHaP),
  plutus-ledger-api, wasm-Plutus fork pins from `nix/wasm/forks.json`.
- Nix flake-parts; the two-phase FOD wasm builder
  `lib.wasm.mkCardanoLedgerWasm`.
- Proof harness: Nix `runCommand` smoke derivations running the `.wasm`
  under `wasmtime`, asserting JSON with `jq`. (There is NO hspec/tasty
  suite in the source — the smoke derivations are the test harness, by
  parity with the inspector.)

## Source → target mapping

| Source (cardano-ledger-inspector) | Target (this repo) |
|---|---|
| `libs/cardano-ledger-inspector/src/Conway/Inspector*.hs` | `cardano-ledger-wasm/src/Conway/Inspector*.hs` (paths unchanged) |
| `libs/cardano-ledger-inspector/app/Main.hs` (WASI reactor) | `cardano-ledger-wasm/app/Main.hs` |
| lib `build-depends` (aeson, base16-bytestring, cardano-ledger-*, plutus-ledger-api, microlens, data-default, …) | `cardano-ledger-wasm.cabal` library stanza |
| `nix/wasm-targets.nix` wasm-tx-inspector call (srpForks=all, withCLibs=true) | this repo's `nix/wasm-targets.nix` |
| `libs/cardano-ledger-inspector/cabal-wasm.project` (all SRP forks) | this repo's `cabal-wasm.project` (forks from forks.json pins) |
| `specs/001-ledger-functional-layer/fixtures/*` | `fixtures/*` |
| inspector flake.nix smoke derivations (identify, witness.plan, witness.attach, intent, input-context, validate, evaluate-scripts) | this repo's `flake.nix` checks/apps |

Note: stub `CardanoLedgerWasm.hs` is deleted; the cborg pin stays in
`forks.json` (ledger closure needs it transitively).

## Slices (bisect-safe, one commit each)

### Slice 1 — kernel library compiles to wasm (additive) (T101–T105)
Additive: add the kernel as the library alongside the existing stub exe,
so the slice is bisect-safe and the next slice has a real RED.
- Copy the five `Conway.Inspector*` modules into `cardano-ledger-wasm/src/`
  (paths unchanged). KEEP `src/CardanoLedgerWasm.hs` and the stub exe
  `app/Main.hs` as-is for this slice.
- `cardano-ledger-wasm.cabal`: library exposes `Conway.Inspector`
  (+ other-modules) AND still `CardanoLedgerWasm`; add the full ledger dep
  set. Exe unchanged (still imports `CardanoLedgerWasm`).
- Rewrite `cabal-wasm.project` to list all `forks.json` SRP stanzas
  (`--sha256` nix32) + the package flags/constraints; `packages: cardano-ledger-wasm`.
- Update `nix/wasm-targets.nix`: `srpForks` = all eight forks,
  `withCLibs = true`, thread `wasiSdk`, recompute `dependenciesHash`
  (set `lib.fakeHash`, run the deps FOD, paste the reported hash).
- Proof (RED-skip rationale in WIP.md: no unit harness — building the
  ledger closure to wasm IS the proof): `nix build .#cardano-ledger-wasm`
  compiles the kernel lib to wasm32-wasi; `nix develop -c just dev-build`;
  `nix flake check`; format; hlint.

### Slice 2 — WASI reactor + fixtures + smoke parity (RED→GREEN) (T201–T206)
Real TDD: the ported smoke fails against the stub exe (RED), then the
reactor makes it pass (GREEN); remove the stub.
- RED: vendor the fixtures into `fixtures/`; add the seven smoke
  derivations to `flake.nix` as `checks` + `apps`, each running
  `wasmtime ${cardano-ledger-wasm}/cardano-ledger-wasm.wasm` against a
  fixture with the inspector's verbatim `jq -e` assertions. Build
  `.#checks.x86_64-linux.tx-identify-smoke` → FAILS (stub exe prints a
  banner, not JSON). Observe RED.
- GREEN: replace `app/Main.hs` with the WASI reactor
  (`Conway.Inspector.runLedgerOperationInput`); delete
  `src/CardanoLedgerWasm.hs`; drop `CardanoLedgerWasm` from the cabal
  library and `cborg` from direct lib deps; exe depends on the lib
  (+ aeson, bytestring, text). Rebuild → smoke passes. Observe GREEN.
- Add CI smoke jobs (`nix run .#<name>-smoke`, `needs: build-gate`)
  mirroring the inspector.
- If dropping the stub changes the dep closure, recompute `dependenciesHash`.
- Proof: `nix flake check` runs every smoke green; full gate green.

## Risks

- The first `prebuiltDeps` compile of the full ledger closure is slow
  (tens of minutes). It is cached in `paolino` Cachix after the first
  run; the `deps` FOD tarball set may already be a cache hit (same closure
  as the inspector). Driver builds in the background and is patient.
- `dependenciesHash` must be recomputed when the closure changes
  (slice 1 only). Slices 2 does not touch the dep set.
- `withCLibs = true` requires `wasiSdk` to be passed into the call — the
  current stub call omits it.

## Orchestrator-owned

- spec/plan/tasks, gate.sh, PR metadata. Everything else → driver+navigator.
