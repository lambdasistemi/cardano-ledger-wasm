# Public API surface for cardano-ledger-inspector.lib.wasm.
#
# Module is system-agnostic: only nixpkgs `lib` is needed to build strings.
# Per-system `pkgs` and `ghcWasmMeta` flow through `mkCardanoLedgerWasm`'s own
# argument list.
{ lib }:

let
  fragment = import ./cabal-project-fragment.nix { inherit lib; };
in
{
  cabalWasmProjectFragment = fragment.stanza;

  mkCardanoLedgerWasm =
    { pkgs
    , ghcWasmMeta
    , wasiSdk ? null
    , chap
    , src
    , packages
    , dependenciesHash
    , srpForks ? []
    , withCLibs ? false
    , projectFile ? "cabal-wasm.project"
    , extraCabalProject ? ""
    , indexState ? null
    , ghcVersion ? "9.12"
    }:
    (import ./mkCardanoLedgerWasm.nix {
      inherit pkgs lib ghcWasmMeta wasiSdk chap;
    }) {
      inherit src packages dependenciesHash srpForks withCLibs
              projectFile extraCabalProject indexState ghcVersion;
    };

  forks = fragment.forks;
}
