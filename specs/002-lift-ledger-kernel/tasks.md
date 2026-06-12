# Tasks — W1 lift the ledger kernel

One commit per slice. Behavior-changing commits carry a `Tasks: T###`
trailer; this file's boxes are checked in the same amended commit.

## Slice 1 — kernel library compiles to wasm (additive)
Commit: `feat: lift Conway ledger kernel library into cardano-ledger-wasm`
Trailer: `Tasks: T101, T102, T103, T104, T105`

- [ ] T101 Copy `Conway.Inspector`, `Conway.Inspector.Common`, `.Context`,
      `.Evaluation`, `.Validation` into `cardano-ledger-wasm/src/Conway/`
      with module paths unchanged (byte-identical source). Keep the stub
      `src/CardanoLedgerWasm.hs` and `app/Main.hs` for this slice.
- [ ] T102 `cardano-ledger-wasm.cabal`: library exposes `Conway.Inspector`
      + other-modules AND still `CardanoLedgerWasm`; add the full ledger dep
      set (aeson, base16-bytestring, bytestring, cardano-crypto-class,
      cardano-ledger-{alonzo,api,binary,conway,core,mary,shelley},
      cardano-slotting, containers, data-default, microlens,
      plutus-ledger-api, text, time). Exe unchanged.
- [ ] T103 Rewrite `cabal-wasm.project` to list every `forks.json` SRP
      stanza (`--sha256` nix32) + package flags/constraints; `packages:
      cardano-ledger-wasm`.
- [ ] T104 Update `nix/wasm-targets.nix`: `srpForks` = all eight forks,
      `withCLibs = true`, thread `wasiSdk`, recompute `dependenciesHash`
      (set `lib.fakeHash`, run the deps FOD, paste the reported hash).
- [ ] T105 Verify: `nix build .#cardano-ledger-wasm` compiles the kernel lib
      to wasm; `nix develop -c just dev-build`; `nix flake check`;
      `nix run .#format-check`; `nix run .#hlint` all green; record in WIP.md.

## Slice 2 — WASI reactor + fixtures + smoke parity (RED→GREEN)
Commit: `feat: wasm reactor entry + fixture smoke parity for the ledger kernel`
Trailer: `Tasks: T201, T202, T203, T204, T205, T206`

- [ ] T201 (RED) Vendor `conway-mainnet-tx.hex`,
      `sundae-swap-usdm-disbursement.hex`,
      `tx-validate-complete-request.json`,
      `tx-evaluate-scripts-complete-request.json` into `fixtures/`; add the
      seven smoke derivations to `flake.nix` (`checks` + `apps`):
      tx-identify, tx-witness-plan, tx-witness-attach, tx-intent,
      tx-input-context, tx-validate, tx-evaluate-scripts — each runs
      `wasmtime <cardano-ledger-wasm.wasm>` against a fixture with the
      inspector's verbatim `jq -e` assertions. Build
      `.#checks.x86_64-linux.tx-identify-smoke` → observe FAIL (stub exe).
- [ ] T202 (GREEN) Replace `app/Main.hs` with the WASI reactor
      (`Conway.Inspector.runLedgerOperationInput`); delete
      `src/CardanoLedgerWasm.hs`; drop `CardanoLedgerWasm` + `cborg` from the
      cabal library; exe depends on the lib (+ aeson, bytestring, text).
- [ ] T203 Rebuild the smoke → observe PASS; confirm all seven smokes green.
- [ ] T204 Add CI smoke jobs to `.github/workflows/ci.yml`
      (`nix run .#<name>-smoke`, `needs: build-gate`).
- [ ] T205 If dropping the stub changed the dep closure, recompute
      `dependenciesHash` in `nix/wasm-targets.nix`.
- [ ] T206 Verify: `nix flake check` runs every smoke green; full
      `./gate.sh` green; record fixture paths + smoke evidence in WIP.md.

## Finalization (orchestrator-owned)
- [ ] T999 PR body audit, drop gate.sh, mark ready.
