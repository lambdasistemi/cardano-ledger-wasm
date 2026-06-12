# Tasks — W1 lift the ledger kernel

One commit per slice. Behavior-changing commits carry a `Tasks: T###`
trailer; this file's boxes are checked in the same amended commit.

## Slice 1 — kernel library compiles to wasm (additive)
Commit: `feat: lift Conway ledger kernel library into cardano-ledger-wasm`
Trailer: `Tasks: T101, T102, T103, T104, T105, T106, T107`

- [X] T101 Copy `Conway.Inspector`, `Conway.Inspector.Common`, `.Context`,
      `.Evaluation`, `.Validation` into `cardano-ledger-wasm/src/Conway/`
      with module paths unchanged (byte-identical source). Keep the stub
      `src/CardanoLedgerWasm.hs` and `app/Main.hs` for this slice.
- [X] T102 `cardano-ledger-wasm.cabal`: library exposes `Conway.Inspector`
      + other-modules AND still `CardanoLedgerWasm`; add the full ledger dep
      set (aeson, base16-bytestring, bytestring, cardano-crypto-class,
      cardano-ledger-{alonzo,api,binary,conway,core,mary,shelley},
      cardano-slotting, containers, data-default, microlens,
      plutus-ledger-api, text, time). Exe unchanged.
- [X] T103 Rewrite `cabal-wasm.project` to list every `forks.json` SRP
      stanza (`--sha256` nix32) + package flags/constraints; `packages:
      cardano-ledger-wasm`. Hackage index-state `2026-04-14T00:00:00Z`,
      CHaP `2026-04-15T11:20:53Z` (Q-001/A-001 — forks.json's 2026-04-15 is
      the FOD truncation cutoff, not the cabal request).
- [X] T104 Update `nix/wasm-targets.nix`: `srpForks` = all eight forks,
      `withCLibs = true`, thread `wasiSdk`, recompute `dependenciesHash`
      (= `sha256-KmY5jyyPc2NFXZSP133Tq6rQWp3d7STwT4O51h7Ukys=`, matches the
      inspector's proven `wasm-tx-inspector` closure).
- [X] T105 (Q-002 → epic-owner Option 1) `flake.nix`: `devShells.default`
      provides the wasm toolchain + `pkg-config` + the shared `nix/wasm/c-libs`
      cLibs (`PKG_CONFIG_PATH`) for interactive use; NO `PREBUILT_DEPS`
      closure-realize on shell entry.
- [X] T106 (Q-002/Q-005 → epic-owner Option 1) `justfile` `dev-build` is a
      CHEAP dev-shell usability gate (mirror mpfs/inspector — never build wasm
      in-shell). The real wasm proof is `nix build .#cardano-ledger-wasm`.
- [X] T107 Verify: `nix build .#cardano-ledger-wasm` (kernel lib → wasm),
      `nix develop -c just dev-build` (cheap), `nix flake check`,
      `nix run .#format-check`, `nix run .#hlint` all green.

## Scope decision (epic owner, Q-005 → A-005): kernel library only

W1 ships the lifted Conway kernel **library** that builds to wasm32-wasi. The
runtime "fixtures pass against the lifted package" proof — a WASI reactor exe +
vendored fixtures + `wasmtime`/`jq` smoke parity (originally planned as slice 2)
— is **deferred to W2 / lambdasistemi/cardano-ledger-inspector#87**, which
re-points the inspector at this kernel and runs its existing
`wasm-tx-inspector` + smokes against the linked external package. This avoids
duplicating the exe + smokes that W2 already owns. The package retains the W0
cborg stub exe as the wasm entry point for this ticket.

(Originally-planned slice-2 tasks T201–T206 dropped here and carried by #87.)

## Finalization (orchestrator-owned)
- [X] T999 PR body audit, scope note, drop gate.sh, mark ready.
