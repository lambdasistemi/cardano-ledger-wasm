{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Shared Conway inspector decoding and JSON rendering primitives.

  This module contains low-level helpers that are used by inspection,
  witness planning, producer-context resolution, and validation.
-}
module Conway.Inspector.Common
    ( InspectError (..)
    , argsObject
    , cborHexText
    , decodeConway
    , decodeTx
    , decodeTxWithBytes
    , decodeVKeyWitness
    , hashHex
    , hexDecode
    , keyHashHex
    , listAt
    , lookupObjectValue
    , lookupValue
    , multiAssetJson
    , rewardAccountJson
    , safeHashHex
    , scriptHashHex
    , txIdHex
    , txInIndex
    , txInJson
    , txInKey
    , txInTxIdHex
    , txOutJson
    , withdrawalRowsJson
    , withdrawalsCount
    ) where

import qualified Cardano.Crypto.Hash as Crypto
import qualified Cardano.Ledger.Address as Addr
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.BaseTypes as BaseTypes
import qualified Cardano.Ledger.Binary as Binary
import qualified Cardano.Ledger.Coin as Coin
import qualified Cardano.Ledger.Conway as Conway
import Cardano.Ledger.Core (TxLevel (..))
import qualified Cardano.Ledger.Credential as Credential
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Mary.Value as Mary
import qualified Cardano.Ledger.Plutus.Data as PData
import qualified Cardano.Ledger.TxIn as TxIn
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Short as SBS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Typeable (Typeable)
import Lens.Micro ((^.))
import qualified PlutusLedgerApi.V1 as PV1

data InspectError
    = MalformedHex String
    | MalformedCbor String
    | MalformedLedgerOperation String
    | UnknownLedgerOperation T.Text
    deriving (Show)

decodeTx
    :: BS.ByteString
    -> Either InspectError (L.Tx TopTx Conway.ConwayEra)
decodeTx =
    fmap snd . decodeTxWithBytes

decodeTxWithBytes
    :: BS.ByteString
    -> Either InspectError (BS.ByteString, L.Tx TopTx Conway.ConwayEra)
decodeTxWithBytes hexBytes = do
    txBytes <- hexDecode hexBytes
    tx <- decodeConway (BSL.fromStrict txBytes)
    pure (txBytes, tx)

hexDecode :: BS.ByteString -> Either InspectError BS.ByteString
hexDecode bs =
    case B16.decode (BS.filter (not . isHexWhitespace) bs) of
        Left err -> Left (MalformedHex err)
        Right ok -> Right ok
  where
    isHexWhitespace c = c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d

decodeConway
    :: BSL.ByteString -> Either InspectError (L.Tx TopTx Conway.ConwayEra)
decodeConway bs =
    case Binary.decodeFullAnnotator
        (Binary.natVersion @11)
        "Tx"
        Binary.decCBOR
        bs of
        Left err -> Left (MalformedCbor (show err))
        Right tx -> Right tx

decodeVKeyWitness
    :: (Typeable kr)
    => BS.ByteString
    -> Either InspectError (Keys.WitVKey kr)
decodeVKeyWitness hexBytes = do
    witnessBytes <- hexDecode hexBytes
    case Binary.decodeFullAnnotator
        (Binary.natVersion @11)
        "WitVKey"
        Binary.decCBOR
        (BSL.fromStrict witnessBytes) of
        Left err -> Left (MalformedCbor (show err))
        Right witness -> Right witness

cborHexText :: (Binary.EncCBOR a) => a -> T.Text
cborHexText =
    T.decodeUtf8
        . B16.encode
        . Binary.serialize' (Binary.natVersion @11)

listAt :: Int -> [a] -> Maybe a
listAt index xs
    | index < 0 = Nothing
    | otherwise = case drop index xs of
        value : _ -> Just value
        [] -> Nothing

argsObject :: Aeson.Value -> Maybe Aeson.Object
argsObject (Aeson.Object obj) = Just obj
argsObject _ = Nothing

lookupValue :: AesonKey.Key -> Aeson.Value -> Maybe Aeson.Value
lookupValue key (Aeson.Object obj) =
    KeyMap.lookup key obj
lookupValue _ _ =
    Nothing

lookupObjectValue :: AesonKey.Key -> Aeson.Object -> Maybe Aeson.Value
lookupObjectValue =
    KeyMap.lookup

{- | Withdrawals are wrapped in a newtype; reach into the Map and count.
  Ledger versions differ on the exact constructor / accessor; use Show
  to bootstrap; replaceable with a proper accessor later.
-}
withdrawalsCount :: L.Withdrawals -> Int
withdrawalsCount (L.Withdrawals m) = Map.size m

withdrawalRowsJson :: L.Withdrawals -> [Aeson.Value]
withdrawalRowsJson (L.Withdrawals m) =
    zipWith withdrawalRowJson [0 :: Int ..] (Map.toList m)

withdrawalRowJson
    :: Int -> (Addr.AccountAddress, Coin.Coin) -> Aeson.Value
withdrawalRowJson index (rewardAccount, coin) =
    case rewardAccountJson rewardAccount of
        Aeson.Object fields ->
            Aeson.Object
                ( fields
                    <> KeyMap.fromList
                        [ ("index", Aeson.toJSON index)
                        ,
                            ( "amount_lovelace"
                            , Aeson.String (T.pack (show (Coin.unCoin coin)))
                            )
                        ]
                )
        _ ->
            Aeson.object
                [ "index" .= index
                , "amount_lovelace" .= T.pack (show (Coin.unCoin coin))
                ]

rewardAccountJson :: Addr.AccountAddress -> Aeson.Value
rewardAccountJson rewardAccount@(Addr.AccountAddress network (Addr.AccountId credential)) =
    Aeson.object
        [ "reward_account_hex"
            .= T.decodeUtf8 (B16.encode (Addr.serialiseRewardAccount rewardAccount))
        , "network" .= networkText network
        , "credential" .= credentialJson credential
        ]

credentialJson :: Credential.Credential r -> Aeson.Value
credentialJson = \case
    Credential.KeyHashObj keyHash ->
        Aeson.object
            [ "kind" .= ("key" :: T.Text)
            , "hash" .= keyHashHex keyHash
            ]
    Credential.ScriptHashObj scriptHash ->
        Aeson.object
            [ "kind" .= ("script" :: T.Text)
            , "hash" .= scriptHashHex scriptHash
            ]

networkText :: BaseTypes.Network -> T.Text
networkText BaseTypes.Mainnet = "mainnet"
networkText BaseTypes.Testnet = "testnet"

-- | Render a Conway TxOut with address, value (coin + assets), and datum.
txOutJson :: L.TxOut Conway.ConwayEra -> Aeson.Value
txOutJson txOut =
    let value = txOut ^. L.valueTxOutL
        Mary.MaryValue c m = value
    in  Aeson.object
            [ "address_hex"
                .= T.decodeUtf8 (B16.encode (Addr.serialiseAddr (txOut ^. L.addrTxOutL)))
            , "coin_lovelace" .= T.pack (show (Coin.unCoin c))
            , "assets" .= multiAssetJson m
            , "datum" .= datumJson (txOut ^. L.datumTxOutL)
            ]

multiAssetJson :: Mary.MultiAsset -> Aeson.Value
multiAssetJson (Mary.MultiAsset m) =
    Aeson.Object $
        KeyMap.fromList
            [ ( AesonKey.fromText (policyHex pid)
              , Aeson.Object $
                    KeyMap.fromList
                        [ ( AesonKey.fromText (assetNameHex an)
                          , Aeson.String (T.pack (show q))
                          )
                        | (an, q) <- Map.toList assetMap
                        ]
              )
            | (pid, assetMap) <- Map.toList m
            ]
  where
    policyHex :: Mary.PolicyID -> T.Text
    policyHex (Mary.PolicyID (Hashes.ScriptHash h)) =
        T.decodeUtf8 (B16.encode (Crypto.hashToBytes h))
    assetNameHex :: Mary.AssetName -> T.Text
    assetNameHex (Mary.AssetName sbs) = T.decodeUtf8 (B16.encode (SBS.fromShort sbs))

-- | Render TxOut datum state. The ledger's `Datum era` is three-cased.
datumJson :: PData.Datum Conway.ConwayEra -> Aeson.Value
datumJson PData.NoDatum =
    Aeson.object ["kind" .= ("no_datum" :: T.Text)]
datumJson (PData.DatumHash h) =
    Aeson.object
        [ "kind" .= ("datum_hash" :: T.Text)
        , "hash"
            .= T.decodeUtf8 (B16.encode (Crypto.hashToBytes (Hashes.extractHash h)))
        ]
datumJson (PData.Datum bd) =
    Aeson.object
        [ "kind" .= ("inline_datum" :: T.Text)
        , "cbor_hex" .= T.decodeUtf8 (B16.encode (Hashes.originalBytes bd))
        , "decoded" .= case PData.binaryDataToData bd of
            d -> plutusDataJson (PData.getPlutusData d)
        ]

{- | Render a Plutus Data AST node as structured JSON so consumers can
read order parameters / certificate payloads / etc. without further
tooling. Untyped: the JSON shape is the AST, not blueprint-driven
record fields, because CIP-57 blueprints frequently leave datums as
opaque @Data@.

Mapping:

* @Constr i fields@ → @{ \"kind\": \"constr\", \"index\": i, \"fields\": [...] }@
* @Map kvs@         → @{ \"kind\": \"map\", \"entries\": [{ \"k\": ..., \"v\": ... }] }@
* @List xs@         → @{ \"kind\": \"list\", \"items\": [...] }@
* @I n@             → @{ \"kind\": \"int\", \"value\": \"<decimal-string>\" }@ (string-encoded
                       to preserve precision for arbitrary-size ints)
* @B bs@            → @{ \"kind\": \"bytes\", \"hex\": \"<hex>\", \"len\": N }@; when
                       the byte string is plausibly UTF-8 readable, an
                       additional @\"utf8\"@ field is included.
-}
plutusDataJson :: PV1.Data -> Aeson.Value
plutusDataJson = \case
    PV1.Constr i fields ->
        Aeson.object
            [ "kind" .= ("constr" :: T.Text)
            , "index" .= i
            , "fields" .= map plutusDataJson fields
            ]
    PV1.Map entries ->
        Aeson.object
            [ "kind" .= ("map" :: T.Text)
            , "entries"
                .= [ Aeson.object
                    [ "k" .= plutusDataJson k
                    , "v" .= plutusDataJson v
                    ]
                   | (k, v) <- entries
                   ]
            ]
    PV1.List xs ->
        Aeson.object
            [ "kind" .= ("list" :: T.Text)
            , "items" .= map plutusDataJson xs
            ]
    PV1.I n ->
        Aeson.object
            [ "kind" .= ("int" :: T.Text)
            , "value" .= T.pack (show n)
            ]
    PV1.B bs ->
        let hex = T.decodeUtf8 (B16.encode (PV1.fromBuiltin (PV1.toBuiltin bs)))
            asUtf8 = case T.decodeUtf8' bs of
                Right t
                    | not (T.null t) && T.all isPrintable t -> Just t
                _ -> Nothing
            base =
                [ "kind" .= ("bytes" :: T.Text)
                , "hex" .= hex
                , "len" .= BS.length bs
                ]
        in  Aeson.object
                ( base
                    <> maybe [] (\u -> ["utf8" .= u]) asUtf8
                )
  where
    isPrintable c =
        c >= ' ' && c <= '~' || c == '\t' || c == '\n'

txInJson :: TxIn.TxIn -> Aeson.Value
txInJson (TxIn.TxIn (TxIn.TxId safeHash) (BaseTypes.TxIx ix)) =
    Aeson.object
        [ "tx_id" .= hashHex (Hashes.extractHash safeHash)
        , "index" .= fromEnum ix
        ]

txInKey :: TxIn.TxIn -> T.Text
txInKey txIn =
    txInTxIdHex txIn <> "#" <> T.pack (show (txInIndex txIn))

txInTxIdHex :: TxIn.TxIn -> T.Text
txInTxIdHex (TxIn.TxIn (TxIn.TxId safeHash) _) =
    hashHex (Hashes.extractHash safeHash)

txInIndex :: TxIn.TxIn -> Int
txInIndex (TxIn.TxIn _ (BaseTypes.TxIx ix)) =
    fromEnum ix

txIdHex :: TxIn.TxId -> T.Text
txIdHex (TxIn.TxId safeHash) =
    hashHex (Hashes.extractHash safeHash)

keyHashHex :: Hashes.KeyHash r -> T.Text
keyHashHex (Hashes.KeyHash h) =
    hashHex h

scriptHashHex :: Hashes.ScriptHash -> T.Text
scriptHashHex (Hashes.ScriptHash h) =
    hashHex h

safeHashHex :: Hashes.SafeHash i -> T.Text
safeHashHex safeHash =
    hashHex (Hashes.extractHash safeHash)

hashHex :: Crypto.Hash h a -> T.Text
hashHex =
    T.decodeUtf8 . B16.encode . Crypto.hashToBytes
