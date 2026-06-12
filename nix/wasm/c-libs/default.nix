# Aggregator for wasm32-wasi-built C libraries needed by the
# cardano-ledger-* closure (transitively via cardano-crypto-praos).
#
# The caller passes in the wasi-sdk provided by ghc-wasm-meta and the
# nixpkgs set from which the secp256k1 and blst sources are reused.
{ pkgs, wasi-sdk }:

let
  libsodium = pkgs.callPackage ./libsodium.nix { inherit wasi-sdk; };

  secp256k1 = (pkgs.callPackage ./secp256k1.nix { inherit wasi-sdk; })
    .overrideAttrs (_: { src = pkgs.secp256k1.src; });

  blst = (pkgs.callPackage ./blst.nix {
    inherit wasi-sdk;
    version = pkgs.blst.version;
  }).overrideAttrs (_: { src = pkgs.blst.src; });
in
{
  inherit libsodium secp256k1 blst;

  # Convenience: all three at once, plus a PKG_CONFIG_PATH pointing at their
  # pkg-config files. Consumers add `all` to nativeBuildInputs and export
  # `pkgConfigPath` as PKG_CONFIG_PATH.
  all = [ libsodium secp256k1 blst ];
  pkgConfigPath = "${libsodium}/lib/pkgconfig:${secp256k1.dev}/lib/pkgconfig:${blst}/lib/pkgconfig";
}
