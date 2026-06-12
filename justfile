default:
    just --list

dev-build:
    wasm32-wasi-cabal --project-file=cabal-wasm.project update
    wasm32-wasi-cabal --project-file=cabal-wasm.project build cardano-ledger-wasm

build:
    nix build .#cardano-ledger-wasm

flake-check:
    nix flake check

format:
    nix develop --quiet -c nix run .#format

format-check:
    nix run --quiet .#format-check

hlint:
    nix run --quiet .#hlint

ci:
    just flake-check
    just dev-build
    just format-check
    just hlint
