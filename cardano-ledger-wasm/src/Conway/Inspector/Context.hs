{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Producer transaction context for resolving transaction inputs.

  The context is explicit ledger evidence supplied by the caller, usually as
  producer transaction CBOR keyed by transaction id.
-}
module Conway.Inspector.Context
    ( ProducerContext (..)
    , ProducerTx (..)
    , contextSummaryJson
    , decodedProducerTxCount
    , inputPolicyFromArgs
    , missingContextTxIns
    , producerContextFromArgs
    , producerContextSupplied
    , producerOutputAt
    , producerTxErrors
    , producerTxLookup
    , producerTxOutput
    , resolvedTxInJson
    ) where

import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.Conway as Conway
import Cardano.Ledger.Core (TxLevel (..))
import qualified Cardano.Ledger.TxIn as TxIn
import Conway.Inspector.Common
    ( InspectError
    , argsObject
    , decodeTx
    , listAt
    , lookupObjectValue
    , lookupValue
    , txInIndex
    , txInKey
    , txInTxIdHex
    , txOutJson
    )
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Lens.Micro ((^.))

data ProducerContext = ProducerContext
    { pcProducerTxs :: Map.Map T.Text ProducerTx
    , ucResolution :: Maybe Aeson.Value
    }

data ProducerTx = ProducerTx
    { ptSource :: T.Text
    , ptDecoded :: Either T.Text (L.Tx TopTx Conway.ConwayEra)
    }

producerContextFromArgs :: Aeson.Value -> ProducerContext
producerContextFromArgs args =
    ProducerContext
        { pcProducerTxs =
            case argsObject args
                >>= lookupObjectValue "context"
                >>= lookupValue "producer_txs" of
                Just (Aeson.Object producerTxs) ->
                    Map.fromList
                        [ ( AesonKey.toText key
                          , producerTxFromValue value
                          )
                        | (key, value) <- KeyMap.toList producerTxs
                        ]
                _ -> Map.empty
        , ucResolution =
            argsObject args
                >>= lookupObjectValue "context"
                >>= lookupValue "resolution"
        }

producerTxFromValue :: Aeson.Value -> ProducerTx
producerTxFromValue value =
    let source =
            case lookupValue "source" value of
                Just (Aeson.String s) -> s
                _ -> "context.producer_txs"
    in  ProducerTx
            { ptSource = source
            , ptDecoded =
                case producerTxCbor value of
                    Nothing -> Left "producer transaction is missing tx_cbor"
                    Just txCbor ->
                        case decodeTx (T.encodeUtf8 txCbor) of
                            Left err -> Left (inspectErrorText err)
                            Right tx -> Right tx
            }

producerTxCbor :: Aeson.Value -> Maybe T.Text
producerTxCbor (Aeson.String txCbor) =
    Just txCbor
producerTxCbor (Aeson.Object obj) =
    case KeyMap.lookup "tx_cbor" obj of
        Just (Aeson.String txCbor) -> Just txCbor
        _ -> Nothing
producerTxCbor _ =
    Nothing

inspectErrorText :: InspectError -> T.Text
inspectErrorText =
    T.pack . show

producerContextSupplied :: ProducerContext -> Bool
producerContextSupplied =
    not . Map.null . pcProducerTxs

inputPolicyFromArgs :: Aeson.Value -> T.Text
inputPolicyFromArgs args =
    case argsObject args >>= lookupObjectValue "input_policy" of
        Just (Aeson.String policy) -> policy
        _ -> "preserve"

missingContextTxIns :: ProducerContext -> [TxIn.TxIn] -> [TxIn.TxIn]
missingContextTxIns context =
    filter (isNothing . producerTxOutput context)

contextSummaryJson
    :: T.Text
    -> ProducerContext
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> Aeson.Value
contextSummaryJson
    inputPolicy
    context
    inputs
    referenceInputs
    missingInputs
    missingReferenceInputs =
        let supplied = producerContextSupplied context
            resolvedInputs =
                length inputs - length missingInputs
            resolvedReferenceInputs =
                length referenceInputs - length missingReferenceInputs
        in  Aeson.object
                [ "input_policy" .= inputPolicy
                , "producer_tx_count" .= Map.size (pcProducerTxs context)
                , "decoded_producer_tx_count" .= decodedProducerTxCount context
                , "producer_tx_errors" .= producerTxErrors context
                , "supplied" .= supplied
                , "complete"
                    .= (supplied && null missingInputs && null missingReferenceInputs)
                , "input_count" .= length inputs
                , "resolved_input_count" .= resolvedInputs
                , "missing_input_count" .= length missingInputs
                , "reference_input_count" .= length referenceInputs
                , "resolved_reference_input_count" .= resolvedReferenceInputs
                , "missing_reference_input_count" .= length missingReferenceInputs
                , "resolution" .= fromMaybe Aeson.Null (ucResolution context)
                ]

decodedProducerTxCount :: ProducerContext -> Int
decodedProducerTxCount context =
    length
        [ ()
        | ProducerTx{ptDecoded = Right _} <- Map.elems (pcProducerTxs context)
        ]

producerTxErrors :: ProducerContext -> [Aeson.Value]
producerTxErrors context =
    [ Aeson.object
        [ "tx_id" .= txId
        , "error" .= err
        ]
    | (txId, ProducerTx{ptDecoded = Left err}) <-
        Map.toList (pcProducerTxs context)
    ]

resolvedTxInJson :: ProducerContext -> TxIn.TxIn -> Aeson.Value
resolvedTxInJson context txIn =
    let key = txInKey txIn
        baseFields =
            [ "key" .= key
            , "tx_id" .= txInTxIdHex txIn
            , "index" .= txInIndex txIn
            ]
    in  case producerTxLookup context txIn of
            Nothing ->
                Aeson.object $
                    baseFields
                        <> [ "resolved" .= False
                           , "reason" .= ("producer transaction CBOR not supplied" :: T.Text)
                           ]
            Just (ProducerTx{ptDecoded = Left err}) ->
                Aeson.object $
                    baseFields
                        <> [ "resolved" .= False
                           , "source" .= ("context.producer_txs" :: T.Text)
                           , "reason" .= err
                           ]
            Just producerTx@ProducerTx{ptDecoded = Right producer} ->
                case producerOutputAt txIn producer of
                    Nothing ->
                        Aeson.object $
                            baseFields
                                <> [ "resolved" .= False
                                   , "source" .= ptSource producerTx
                                   , "reason" .= ("producer transaction output index not found" :: T.Text)
                                   ]
                    Just txOut ->
                        Aeson.object $
                            baseFields
                                <> [ "resolved" .= True
                                   , "source" .= ptSource producerTx
                                   , "tx_out" .= txOutJson txOut
                                   ]

producerTxLookup :: ProducerContext -> TxIn.TxIn -> Maybe ProducerTx
producerTxLookup context txIn =
    Map.lookup (txInTxIdHex txIn) (pcProducerTxs context)

producerTxOutput
    :: ProducerContext
    -> TxIn.TxIn
    -> Maybe (L.TxOut Conway.ConwayEra)
producerTxOutput context txIn = do
    ProducerTx{ptDecoded = Right producer} <-
        producerTxLookup context txIn
    producerOutputAt txIn producer

producerOutputAt
    :: TxIn.TxIn
    -> L.Tx TopTx Conway.ConwayEra
    -> Maybe (L.TxOut Conway.ConwayEra)
producerOutputAt txIn producer =
    listAt (txInIndex txIn) $
        toList (producer ^. (L.bodyTxL . L.outputsTxBodyL))
