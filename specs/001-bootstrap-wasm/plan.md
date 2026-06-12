# 001 — Implementation Plan

Reference repo: `/code/cardano-ledger-inspector` (read its `flake.nix`,
`nix/wasm/`, `nix/wasm-targets.nix`, `nix/wasm/smoke/`, `justfile`, and CI).
The new repo **vendors** the inspector's wasm toolchain and stubs a trivial
package; it does not depend on the inspector flake.

## Target layout

```
flake.nix                       # mirrors inspector inputs/overlays; exposes
                                #   lib.wasm, packages.cardano-ledger-wasm,
                                #   packages.default, apps.format-check,
                                #   apps.hlint, devShells.default
flake.lock                      # committed
cabal-wasm.project              # wasm cabal project (packages: cardano-ledger-wasm,
                                #   CHaP repo + index-state + cborg fork, flags)
cabal.project                   # thin: points cabal at the package (dev convenience)
cardano-ledger-wasm/
  cardano-ledger-wasm.cabal     # stub: library CardanoLedgerWasm + exe cardano-ledger-wasm
  src/CardanoLedgerWasm.hs
  app/Main.hs
nix/wasm/                       # VENDORED verbatim from inspector:
  default.nix
  mkCardanoLedgerWasm.nix
  cabal-project-fragment.nix
  forks.json                    # carries the wasm-Plutus 1.65.0.0-wasm32.1 pin
  c-libs/{default,blst,libsodium,secp256k1}.nix
nix/wasm-targets.nix            # wires cardano-ledger-wasm via lib.wasm.mkCardanoLedgerWasm
justfile                        # dev-build, build, flake-check, format(-check), hlint, ci
fourmolu.yaml                   # 70-col leading-comma (copy inspector)
.github/workflows/ci.yml        # Build Gate / Dev shell / Format / Hlint + version-drift step
.github/workflows/release.yml   # release-please (manifest mode) + (no publish for W0)
.github/workflows/sync-cabal-version.yml
release-please-config.json
.release-please-manifest.json
```

## Toolchain mirroring (slice S1)

- Copy `nix/wasm/{default.nix,mkCardanoLedgerWasm.nix,cabal-project-fragment.nix,forks.json,c-libs/*}`
  **verbatim** from the inspector. `forks.json` already contains the full pin
  set (plutus/cborg/hs-memory/foundation/network/double-conversion/criterion/
  lmdb-mock) and the wasm-Plutus fork — keep it intact for W1.
- `flake.nix` inputs copy the inspector's revs: `haskellNix`, `hackageNix`,
  `CHaP`, `ghc-wasm-meta` (gitlab), `iohk-nix`, `flake-parts`. Drop the
  purescript/mkSpago inputs (no UI in W0).
- `pkgs` overlays: `iohkNix.overlays.crypto`, `haskellNix.overlay`,
  `iohkNix.overlays.haskell-nix-crypto`, `iohkNix.overlays.cardano-lib`.
- `ghcWasmMeta = ghc-wasm-meta.packages.<sys>.all_9_12`,
  `wasiSdk = ghc-wasm-meta.packages.<sys>.wasi-sdk`.

## Stub package (slice S1)

- Mirror `nix/wasm/smoke/` exactly, renamed:
  - `cabal-wasm.project` at repo root, `packages: cardano-ledger-wasm`, CHaP
    repo block + index-state + `allow-newer` + the cborg `source-repository-package`
    + the wasm package flags (cardano-crypto-praos/crypton/atomic-counter/
    digest/plutus-core), `tests: False`, `benchmarks: False`.
  - `cardano-ledger-wasm.cabal`: `library` exposing `CardanoLedgerWasm`
    (depends `base`, `bytestring`, `cborg`) + `executable cardano-ledger-wasm`
    (`Main.hs`). `license: MIT`, haddock on exports, `-Wall`.
  - `src/CardanoLedgerWasm.hs`, `app/Main.hs`: trivial (e.g. CBOR round-trip a
    constant + print a banner). Keep it `cabal check`-clean and fourmolu-clean.
- `nix/wasm-targets.nix`: one target,
  `cardano-ledger-wasm = libWasm.mkCardanoLedgerWasm { inherit pkgs ghcWasmMeta chap; src = ./..; packages = ["cardano-ledger-wasm"]; srpForks = ["cborg"]; dependenciesHash = <computed>; }`.
  `withCLibs = false` (cborg-only stub — no wasm C libs needed). Compute
  `dependenciesHash`: first build with `pkgs.lib.fakeHash`, read the hash Nix
  prints, lock it.
- flake outputs: `packages.cardano-ledger-wasm` = that derivation;
  `packages.default = cardano-ledger-wasm` (so bare `nix build` yields the
  `.wasm`); `apps.format-check`, `apps.hlint` (writeShellApplication, fourmolu/
  hlint over `cardano-ledger-wasm nix/wasm`); `devShells.default` with
  `ghcWasmMeta`, `wasiSdk`, `just`, `wasmtime`, `fourmolu`, `hlint`, `jq` so
  `wasm32-wasi-cabal` is on PATH.

## Dev-shell gate (slice S1)

- `justfile` recipe `dev-build`:
  `wasm32-wasi-cabal --project-file=cabal-wasm.project build cardano-ledger-wasm`.
- The mandatory gate is `nix develop -c just dev-build` — a real wasm cabal
  build inside the shell (catches a shell that builds packaged but not in
  `nix develop`; see the `nix` skill's "dev shell needs its own CI gate").
- `flake check` builds `checks` — model at least the stub package build as a
  check so `nix flake check` is meaningful (or expose the wasm derivation under
  `checks` too).

## CI (slice S2) — `.github/workflows/ci.yml`, `runs-on: nixos`

- `build-gate` (name **Build Gate**): cachix-action@v17 (name `paolino`),
  `nix build .#cardano-ledger-wasm` + `nix flake check`.
- `dev-shell` (name **Dev shell**, `needs: build-gate`):
  `nix develop --quiet -c just dev-build`.
- `format-check` (name **Format (fourmolu)**, needs build-gate):
  `nix run --quiet .#format-check`.
- `hlint` (name **Hlint**, needs build-gate): `nix run --quiet .#hlint`.
- `version-drift` step (can live in build-gate or its own job): assert the
  `.cabal` `version` == PVP-normalized `.release-please-manifest.json` `"."`.
- `concurrency` cancel-in-progress; `on: [pull_request:main, push:main]`.

## Release (slice S3) — manifest mode (`haskell-release-workflow`)

- `release-please-config.json`: `release-type: simple`, package `.` with
  `package-name: cardano-ledger-wasm`, `bump-minor-pre-major: true`,
  `bump-patch-for-minor-pre-major: true`, `include-component-in-tag: false`,
  changelog sections feat/fix/perf/refactor(hidden)/etc.
- `.release-please-manifest.json`: `{ ".": "0.1.0" }` (cabal stub version
  `0.1.0.0`).
- `release.yml`: `on: [push:main, workflow_dispatch]`,
  `googleapis/release-please-action@v4` with the config + manifest files. **No
  publish job for W0** (release pipeline only needs to *validate*).
- `sync-cabal-version.yml`: `on: pull_request [opened, synchronize]`, guarded
  `if: startsWith(github.head_ref, 'release-please--')`; reads manifest `"."`,
  maps semver→PVP (`x.y.z`→`x.y.z.0`), `sed`s the `.cabal` `version:`, commits
  + pushes to the release branch.
- CI drift step ("Cabal version matches manifest") fails when they disagree.

## Gate / verification

`./gate.sh` (orchestrator-owned, added before S1) runs: `git diff --check`,
`nix build .#cardano-ledger-wasm`, `nix flake check`,
`nix develop -c just dev-build`, `nix run .#format-check`, `nix run .#hlint`.
Every slice driver runs it before reporting; the orchestrator reruns it before
push. CI is never used to find our own errors.

## Risks

- **Heavy first build**: the wasm dep FOD + cborg/base compile is slow and
  needs network. `dependenciesHash` must be computed by the driver (fakeHash →
  read printed hash). Budget time.
- **fakeHash flow**: don't guess the hash; let Nix print the mismatch and copy
  the `got:` value.
- **store-path FOD scan**: keep nix32 hashes in `forks.json` (already so).
