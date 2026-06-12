# cardano-ledger-wasm

Cardano ledger operations compiled to `wasm32-wasi`.

Extracted from [`cardano-ledger-inspector`](https://github.com/lambdasistemi/cardano-ledger-inspector)
as a standalone home for the wasm toolchain and the ledger kernel.

> Bootstrap in progress (epic #84 / W0). The buildable skeleton lands via the
> `feat/wasm-skeleton` PR.

## Build

```sh
nix build            # produces the wasm32-wasi artifact from the stub
nix flake check      # runs the flake checks
nix develop -c just ci   # local CI gate (once the skeleton lands)
```

## License

MIT — see [LICENSE](./LICENSE).
