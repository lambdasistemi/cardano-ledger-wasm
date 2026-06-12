{ pkgs
, libWasm
, ghcWasmMeta
, wasiSdk
, chap
}:
{
  cardano-ledger-wasm = libWasm.mkCardanoLedgerWasm {
    inherit pkgs ghcWasmMeta wasiSdk chap;
    src = ./..;
    packages = [ "cardano-ledger-wasm" ];
    srpForks = [
      "plutus" "hs-memory" "criterion-measurement" "haskell-lmdb-mock"
      "double-conversion" "cborg" "foundation" "network"
    ];
    withCLibs = true;
    dependenciesHash = "sha256-KmY5jyyPc2NFXZSP133Tq6rQWp3d7STwT4O51h7Ukys=";
  };
}
