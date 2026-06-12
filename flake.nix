{
  description = "Cardano ledger operations compiled to WASI";

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://paolino.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "paolino.cachix.org-1:ecmgO3CXdgSWA2cHlm4srknd/cLFMLmK3i3NrzeDFaE="
    ];
  };

  inputs = {
    haskellNix = {
      url = "github:input-output-hk/haskell.nix/ef52c36b9835c77a255befe2a20075ba71e3bfab";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url = "github:input-output-hk/hackage.nix/c3d44f9e5d929e86a45a48246667ea25cd1f11df";
      flake = false;
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix/f444d972c301ddd9f23eac4325ffcc8b5766eee9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages/00c90c10812a98ef9680f4bfa269d42366d46d89";
      flake = false;
    };
    ghc-wasm-meta.url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
  };

  outputs =
    inputs@
    { self
    , nixpkgs
    , flake-parts
    , haskellNix
    , iohkNix
    , CHaP
    , ghc-wasm-meta
    , ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];

      flake = {
        lib.wasm = import ./nix/wasm { lib = nixpkgs.lib; };
      };

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              iohkNix.overlays.crypto
              haskellNix.overlay
              iohkNix.overlays.haskell-nix-crypto
              iohkNix.overlays.cardano-lib
            ];
          };

          ghcWasmMeta = ghc-wasm-meta.packages.${system}.all_9_12;
          wasiSdk = ghc-wasm-meta.packages.${system}.wasi-sdk;
          chap = CHaP;

          wasmTargets = import ./nix/wasm-targets.nix {
            inherit pkgs ghcWasmMeta wasiSdk chap;
            libWasm = self.lib.wasm;
          };

          mkApp = drv: {
            type = "app";
            program = pkgs.lib.getExe drv;
          };

          format = pkgs.writeShellApplication {
            name = "format";
            runtimeInputs = [
              pkgs.findutils
              pkgs.haskellPackages.fourmolu
            ];
            text = ''
              find cardano-ledger-wasm nix/wasm -type f -name '*.hs' \
                -exec fourmolu -m inplace {} +
            '';
          };

          format-check = pkgs.writeShellApplication {
            name = "format-check";
            runtimeInputs = [
              pkgs.findutils
              pkgs.haskellPackages.fourmolu
            ];
            text = ''
              find cardano-ledger-wasm nix/wasm -type f -name '*.hs' \
                -exec fourmolu -m check {} +
            '';
          };

          hlint = pkgs.writeShellApplication {
            name = "hlint";
            runtimeInputs = [ pkgs.haskellPackages.hlint ];
            text = ''
              hlint cardano-ledger-wasm nix/wasm
            '';
          };
        in
        {
          packages = {
            inherit (wasmTargets) cardano-ledger-wasm;
            default = wasmTargets.cardano-ledger-wasm;
          };

          checks = {
            cardano-ledger-wasm = wasmTargets.cardano-ledger-wasm;
          };

          apps = {
            format = mkApp format;
            format-check = mkApp format-check;
            hlint = mkApp hlint;
          };

          devShells.default = pkgs.mkShell {
            buildInputs = [
              ghcWasmMeta
              wasiSdk
              pkgs.just
              pkgs.wasmtime
              pkgs.jq
              pkgs.haskellPackages.fourmolu
              pkgs.haskellPackages.hlint
            ];
          };
        };
    };
}
