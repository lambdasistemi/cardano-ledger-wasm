# W1 — Lift the Conway ledger kernel into `cardano-ledger-wasm`

Issue: lambdasistemi/cardano-ledger-inspector#86 — part of epic #84, blocked-by W0 (#85, merged).

## Context

W0 bootstrapped this repo with a buildable wasm32-wasi skeleton: the
two-phase FOD wasm builder (`nix/wasm/mkCardanoLedgerWasm.nix`), the
fork pin set (`nix/wasm/forks.json`), and the flake export
`lib.wasm = { mkCardanoLedgerWasm, forks, cabalWasmProjectFragment }`.
The package `cardano-ledger-wasm` is currently an empty-but-buildable
cborg round-trip stub.

The Conway ledger-operations library lives in
`cardano-ledger-inspector` at `libs/cardano-ledger-inspector` as the
module family `Conway.Inspector.*` plus a WASI reactor exe. W2 (#87)
will re-point the inspector at this repo's package **by those module
names**, so the module paths are a contract.

## P1 user story

As a downstream wasm consumer (the inspector in W2, mpfs-verify in W4),
I can depend on `cardano-ledger-wasm` and get the Conway ledger
operations — decode/identify, tx.intent, tx.witness.*, tx.validate,
tx.evaluate.scripts — compiled to wasm32-wasi, with the exact module
paths `Conway.Inspector` / `Conway.Inspector.{Common,Context,Evaluation,Validation}`.

## User stories

- As an integrator, the repo builds a standalone `cardano-ledger-wasm.wasm`
  reactor via `nix build .#cardano-ledger-wasm`.
- As the inspector (W2), the lifted modules keep stable paths so a future
  `import Conway.Inspector` resolves against this package unchanged.
- As CI, the existing inspector ledger fixtures (conway-mainnet-tx,
  sundae-swap, the validate/evaluate request JSON) pass against the
  lifted package, proving behavior parity.
- As a developer, `nix develop -c just dev-build` compiles the local
  package offline against the prebuilt wasm dep closure.

## Functional requirements

- FR1: Package `cardano-ledger-wasm` exposes library module
  `Conway.Inspector` with other-modules
  `Conway.Inspector.{Common,Context,Evaluation,Validation}` — byte-identical
  source to the inspector's lib, **no module renames**.
- FR2: The package's wasm exe target `cardano-ledger-wasm` is the WASI
  reactor (stdin JSON/hex envelope → stdout JSON) driven by
  `Conway.Inspector.runLedgerOperationInput`.
- FR3: The stub module `CardanoLedgerWasm` and the cborg round-trip are
  removed; cborg remains only as a transitive fork pin where the ledger
  closure needs it.
- FR4: The wasm build target wires the full ledger closure:
  `srpForks` = all pins in `forks.json`, `withCLibs = true` (libsodium /
  secp256k1 / blst built for wasm32-wasi), `wasiSdk` threaded through, and
  a recomputed `dependenciesHash`.
- FR5: `cabal-wasm.project` lists every `source-repository-package` fork
  from `forks.json` plus the package flags/constraints the ledger closure
  needs.
- FR6: The fixtures (conway-mainnet-tx.hex, sundae-swap-usdm-disbursement.hex,
  tx-validate-complete-request.json, tx-evaluate-scripts-complete-request.json)
  are vendored into this repo, and the inspector's `wasmtime`+`jq` smoke
  derivations for the lifted operations are ported as flake `checks`/`apps`
  and CI jobs.
- FR7: The W0 design-addendum export (`lib.wasm.{mkCardanoLedgerWasm,forks,
  cabalWasmProjectFragment}`) remains intact and is the single source of
  truth for the fork pin — this repo does not duplicate the pin elsewhere.

## Success criteria

- SC1: `nix build .#cardano-ledger-wasm` produces a wasm32-wasi reactor
  that links the Conway ledger kernel.
- SC2: `nix flake check` is green, including every ported smoke check;
  each smoke runs the built `.wasm` under `wasmtime` against a vendored
  fixture and asserts the JSON response with `jq`.
- SC3: `nix develop -c just dev-build` succeeds.
- SC4: `nix run .#format-check` and `nix run .#hlint` pass over the lifted
  modules.
- SC5: CI is green on all jobs (build-gate, dev-shell, format, hlint, smokes).

## Out of scope (later tickets)

- W2 (#87): re-pointing the inspector at this package.
- W3 (#88): releasing v0.1.
- The inspector's UI, OpenAPI/swagger, extism-spike, deep-diagnosis, and
  playwright surfaces — those are not part of the lifted kernel.
