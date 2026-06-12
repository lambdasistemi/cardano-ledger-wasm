default:
    just --list

dev-build:
    #!/usr/bin/env bash
    set -euo pipefail

    : "${CARDANO_LEDGER_WASM_PREBUILT_DEPS:?missing dev-shell offline cabal cache}"

    cabal_dir="$(mktemp -d)"
    project_file="$(mktemp -p "$PWD" .cabal-wasm-offline.XXXXXX.project)"
    build_dir="$(mktemp -d -p "$PWD" .dist-newstyle-wasm-dev.XXXXXX)"
    cleanup() {
      rm -rf "$cabal_dir" "$project_file" "$build_dir"
    }
    trap cleanup EXIT

    cp -rL "$CARDANO_LEDGER_WASM_PREBUILT_DEPS/cabal/." "$cabal_dir/"
    cp "$CARDANO_LEDGER_WASM_PREBUILT_DEPS/cabal-wasm.project" "$project_file"
    chmod -R u+w "$cabal_dir" "$build_dir"
    chmod u+w "$project_file"
    rm -rf "$cabal_dir/store"

    CABAL_DIR="$cabal_dir" wasm32-wasi-cabal \
      --project-file="$project_file" \
      build \
      --builddir="$build_dir" \
      cardano-ledger-wasm

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
