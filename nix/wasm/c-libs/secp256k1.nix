# Ported from IntersectMBO/cardano-api master nix/secp256k1.nix.
# Builds libsecp256k1 for wasm32-wasi. Caller supplies `src` (typically
# `nixpkgs.secp256k1.src`) via overrideAttrs.
{
  stdenvNoCC,
  autoreconfHook,
  pkg-config,
  wasi-sdk,
}:
stdenvNoCC.mkDerivation {
  name = "libsecp256k1-wasm32-wasi";

  outputs = [
    "out"
    "dev"
  ];

  nativeBuildInputs = [
    wasi-sdk
    autoreconfHook
  ];

  configureFlags = [
    "--host=wasm32-wasi"
    "--enable-module-schnorrsig"
    "SECP_CFLAGS=-fPIC"
  ];

  postInstall = ''
    wasm32-wasi-clang -shared -Wl,--whole-archive $out/lib/libsecp256k1.a -o $out/lib/libsecp256k1.so
  '';
}
