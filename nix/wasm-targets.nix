{ pkgs
, libWasm
, ghcWasmMeta
, wasiSdk
, chap
}:
{
  cardano-ledger-wasm = libWasm.mkCardanoLedgerWasm {
    inherit pkgs ghcWasmMeta chap;
    src = ./..;
    packages = [ "cardano-ledger-wasm" ];
    srpForks = [ "cborg" ];
    withCLibs = false;
    dependenciesHash = "sha256-77vajpEB8aCCJUaWtFGLLFEnSVMBeXKf9uEYLwA+a+E=";
  };
}
