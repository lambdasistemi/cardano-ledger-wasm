{- | Minimal library proving the WASM toolchain, CHaP index, and
  cborg source-repository-package fork all build together.
-}
module CardanoLedgerWasm
    ( banner
    , roundTripConstant
    , roundTripInt
    ) where

import Codec.CBOR.Decoding (decodeInt)
import Codec.CBOR.Encoding (encodeInt)
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Write (toLazyByteString)

-- | Human-readable marker emitted by the skeleton executable.
banner :: String
banner = "cardano-ledger-wasm cborg round-trip OK"

-- | Round-trip the fixed skeleton constant through CBOR.
roundTripConstant :: Either String Int
roundTripConstant = roundTripInt 42

-- | Encode and decode an integer with cborg.
roundTripInt :: Int -> Either String Int
roundTripInt n =
    case deserialiseFromBytes decodeInt (toLazyByteString (encodeInt n)) of
        Left err -> Left (show err)
        Right (_, n') -> Right n'
