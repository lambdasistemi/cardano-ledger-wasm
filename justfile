default:
    just --list

dev-build:
    #!/usr/bin/env bash
    set -euo pipefail
    # Cheap dev-shell usability gate (Option 1: mirror mpfs/inspector -- never
    # build wasm in-shell). The real wasm build is `nix build .#cardano-ledger-wasm`.
    wasm32-wasi-cabal --version
    pkg-config --version
    fourmolu --version
    hlint --version

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
