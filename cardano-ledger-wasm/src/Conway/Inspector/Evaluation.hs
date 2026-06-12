{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Conway phase-2 script evaluation.

  This module uses upstream ledger script evaluation over explicit context.
  It never mutates the candidate transaction or returns patched CBOR.
-}
module Conway.Inspector.Evaluation
    ( evaluateScriptsJson
    ) where

import qualified Cardano.Ledger.Alonzo.Plutus.Evaluate as Evaluate
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.BaseTypes as BaseTypes
import qualified Cardano.Ledger.Conway as Conway
import qualified Cardano.Ledger.Conway.Scripts as ConwayScripts
import Cardano.Ledger.Core (TxLevel (..))
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Plutus.Data as PData
import qualified Cardano.Ledger.Plutus.ExUnits as ExUnits
import qualified Cardano.Ledger.Shelley.LedgerState as ShelleyState
import qualified Cardano.Ledger.TxIn as TxIn
import qualified Cardano.Slotting.EpochInfo as EpochInfo
import qualified Cardano.Slotting.Time as SlottingTime
import Conway.Inspector.Common
    ( argsObject
    , lookupObjectValue
    , lookupValue
    , safeHashHex
    , txIdHex
    , txInIndex
    , txInKey
    , txInTxIdHex
    , txOutJson
    )
import Conway.Inspector.Context
    ( ProducerContext (..)
    , ProducerTx (..)
    , decodedProducerTxCount
    , inputPolicyFromArgs
    , missingContextTxIns
    , producerContextFromArgs
    , producerContextSupplied
    , producerOutputAt
    , producerTxErrors
    , producerTxLookup
    , producerTxOutput
    )
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word32, Word64)
import Lens.Micro ((^.))
import Text.Read (readMaybe)

type RedeemerReport =
    Map.Map
        (L.PlutusPurpose L.AsIx Conway.ConwayEra)
        ( Either
            (Evaluate.TransactionScriptFailure Conway.ConwayEra)
            ([T.Text], ExUnits.ExUnits)
        )

data EvaluationRun
    = EvaluationNotRun T.Text
    | EvaluationReport RedeemerReport

evaluateScriptsJson
    :: Aeson.Value
    -> L.Tx TopTx Conway.ConwayEra
    -> Aeson.Value
evaluateScriptsJson args tx =
    let body = tx ^. L.bodyTxL
        wits = tx ^. Core.witsTxL
        redeemers = Map.toList (L.unRedeemers (wits ^. L.rdmrsTxWitsL))
        context = producerContextFromArgs args
        inputPolicy = inputPolicyFromArgs args
        contextValue = argsObject args >>= lookupObjectValue "context"
        inputs = toList (body ^. L.inputsTxBodyL)
        referenceInputs = toList (body ^. L.referenceInputsTxBodyL)
        unresolvedInputs = missingContextTxIns context inputs
        unresolvedReferenceInputs = missingContextTxIns context referenceInputs
        missingProducerInputs =
            filter (isNothing . producerTxLookup context) inputs
        missingProducerReferenceInputs =
            filter (isNothing . producerTxLookup context) referenceInputs
        (_network, networkMissing, networkErrors) =
            requiredContextField
                "network"
                "network"
                "Supply the network for script evaluation."
                parseNetworkValue
                contextValue
        (slot, slotMissing, slotErrors) =
            requiredContextField
                "slot"
                "slot"
                "Supply the current slot for script evaluation."
                (parseWord64Value "slot")
                contextValue
        (epoch, epochMissing, epochErrors) =
            requiredContextField
                "epoch"
                "epoch"
                "Supply the current epoch for script evaluation."
                (parseWord64Value "epoch")
                contextValue
        (pparams, pparamsMissing, pparamsErrors) =
            requiredContextField
                "protocol_parameters"
                "protocol_parameters"
                "Supply a complete Conway protocol-parameter object."
                parseProtocolParametersValue
                contextValue
        contextErrors =
            if null redeemers
                then []
                else
                    inputPolicyErrors inputPolicy
                        <> unsupportedUtxoJsonErrors contextValue
                        <> producerDecodeContextErrors context
                        <> producerTxIdContextErrors context
                        <> producerOutputIndexContextErrors
                            "input"
                            "inputs"
                            context
                            inputs
                        <> producerOutputIndexContextErrors
                            "reference_input"
                            "reference_inputs"
                            context
                            referenceInputs
                        <> networkErrors
                        <> slotErrors
                        <> epochErrors
                        <> pparamsErrors
        missingContext =
            if null redeemers
                then []
                else
                    zipWith
                        (missingSourceOutputContextJson "input" "inputs")
                        [0 :: Int ..]
                        missingProducerInputs
                        <> zipWith
                            (missingSourceOutputContextJson "reference_input" "reference_inputs")
                            [0 :: Int ..]
                            missingProducerReferenceInputs
                        <> networkMissing
                        <> slotMissing
                        <> epochMissing
                        <> pparamsMissing
        evaluationRun =
            runScriptEvaluation
                contextErrors
                missingContext
                slot
                epoch
                pparams
                context
                inputs
                referenceInputs
                tx
        failures = evaluationFailures evaluationRun
        status =
            evaluationStatus
                (null redeemers)
                contextErrors
                missingContext
                evaluationRun
        complete =
            null contextErrors
                && null missingContext
                && case status of
                    "succeeded" -> True
                    "failed" -> True
                    "not_applicable" -> True
                    _ -> False
        scriptsEvaluateForSuppliedContext =
            case status of
                "succeeded" -> Aeson.Bool True
                "failed" -> Aeson.Bool False
                _ -> Aeson.Null
        totalExUnits =
            totalEvaluatedExUnits evaluationRun
        warnings =
            evaluationWarnings status
    in  Aeson.object
            [ "status" .= status
            , "scripts_evaluate_for_supplied_context"
                .= scriptsEvaluateForSuppliedContext
            , "complete" .= complete
            , "tx_id" .= txIdHex (Core.txIdTx tx)
            , "body_hash" .= txIdHex (Core.txIdTxBody body)
            , "redeemers"
                .= map
                    (redeemerEvaluationJson evaluationRun missingContext)
                    redeemers
            , "total_ex_units" .= totalExUnits
            , "failures" .= failures
            , "missing_context" .= missingContext
            , "resolved_inputs"
                .= zipWith
                    (evaluationResolvedTxInJson "input" "inputs" context)
                    [0 :: Int ..]
                    inputs
            , "resolved_reference_inputs"
                .= zipWith
                    ( evaluationResolvedTxInJson
                        "reference_input"
                        "reference_inputs"
                        context
                    )
                    [0 :: Int ..]
                    referenceInputs
            , "context"
                .= evaluationContextSummaryJson
                    inputPolicy
                    context
                    inputs
                    referenceInputs
                    unresolvedInputs
                    unresolvedReferenceInputs
                    slot
                    epoch
                    complete
                    (length redeemers)
                    (evaluatedRedeemerCount evaluationRun)
            , "warnings" .= warnings
            , "errors" .= contextErrors
            ]

runScriptEvaluation
    :: [Aeson.Value]
    -> [Aeson.Value]
    -> Maybe Word64
    -> Maybe Word64
    -> Maybe (Core.PParams Conway.ConwayEra)
    -> ProducerContext
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> L.Tx TopTx Conway.ConwayEra
    -> EvaluationRun
runScriptEvaluation contextErrors missingContext slot _epoch pparams context inputs referenceInputs tx
    | not (null contextErrors) =
        EvaluationNotRun
            "Script evaluation was not run because evaluation context is invalid."
    | not (null missingContext) =
        EvaluationNotRun
            "Script evaluation was not run because evaluation context is incomplete."
    | otherwise =
        case (slot, pparams) of
            (Just _slot', Just pparams') ->
                EvaluationReport $
                    Evaluate.evalTxExUnitsWithLogs
                        pparams'
                        tx
                        (evaluationSourceUTxO context (inputs <> referenceInputs))
                        evaluationEpochInfo
                        evaluationSystemStart
            _ ->
                EvaluationNotRun
                    "Script evaluation was not run because required context parsing did not produce ledger values."

evaluationEpochInfo :: EpochInfo.EpochInfo (Either T.Text)
evaluationEpochInfo =
    EpochInfo.fixedEpochInfo
        (BaseTypes.EpochSize 432000)
        (SlottingTime.mkSlotLength 1)

evaluationSystemStart :: SlottingTime.SystemStart
evaluationSystemStart =
    SlottingTime.SystemStart (posixSecondsToUTCTime 0)

evaluationSourceUTxO
    :: ProducerContext
    -> [TxIn.TxIn]
    -> ShelleyState.UTxO Conway.ConwayEra
evaluationSourceUTxO context txIns =
    ShelleyState.UTxO $
        Map.fromList
            [ (txIn, txOut)
            | txIn <- txIns
            , Just txOut <- [producerTxOutput context txIn]
            ]

evaluationStatus
    :: Bool
    -> [Aeson.Value]
    -> [Aeson.Value]
    -> EvaluationRun
    -> T.Text
evaluationStatus noRedeemers contextErrors missingContext evaluationRun
    | noRedeemers = "not_applicable"
    | not (null contextErrors) = "rejected"
    | not (null missingContext) = "incomplete"
    | otherwise =
        case evaluationRun of
            EvaluationReport report
                | any isEvaluationFailure (Map.elems report) -> "failed"
                | otherwise -> "succeeded"
            EvaluationNotRun _ -> "incomplete"
  where
    isEvaluationFailure (Left _) = True
    isEvaluationFailure (Right _) = False

redeemerEvaluationJson
    :: EvaluationRun
    -> [Aeson.Value]
    -> ( L.PlutusPurpose L.AsIx Conway.ConwayEra
       , (PData.Data Conway.ConwayEra, ExUnits.ExUnits)
       )
    -> Aeson.Value
redeemerEvaluationJson evaluationRun missingContext (purpose, (redeemerData, budget)) =
    let maybeResult =
            case evaluationRun of
                EvaluationReport report -> Map.lookup purpose report
                EvaluationNotRun _ -> Nothing
        key = purposeKey purpose
        baseFields =
            [ "key" .= key
            , "purpose" .= purposeKind purpose
            , "index" .= purposeIndex purpose
            , "path" .= purposePath purpose
            , "redeemer_data_hash" .= safeHashHex (PData.hashData redeemerData)
            , "budget_ex_units" .= exUnitsJson budget
            , "warnings" .= ([] :: [T.Text])
            ]
    in  case maybeResult of
            Just (Right (logs, evaluated)) ->
                Aeson.object $
                    baseFields
                        <> [ "status" .= ("succeeded" :: T.Text)
                           , "evaluated_ex_units" .= exUnitsJson evaluated
                           , "logs" .= logs
                           , "missing_context" .= ([] :: [T.Text])
                           ]
            Just (Left failure) ->
                Aeson.object $
                    baseFields
                        <> [ "status" .= ("failed" :: T.Text)
                           , "evaluated_ex_units" .= Aeson.Null
                           , "failure" .= evaluationFailureJson purpose failure
                           , "missing_context" .= ([] :: [T.Text])
                           ]
            Nothing ->
                Aeson.object $
                    baseFields
                        <> [ "status" .= ("not_evaluated" :: T.Text)
                           , "evaluated_ex_units" .= Aeson.Null
                           , "missing_context" .= missingKindsFor key missingContext
                           ]

evaluationFailures :: EvaluationRun -> [Aeson.Value]
evaluationFailures (EvaluationReport report) =
    [ evaluationFailureJson purpose failure
    | (purpose, Left failure) <- Map.toList report
    ]
evaluationFailures (EvaluationNotRun _) = []

evaluationFailureJson
    :: L.PlutusPurpose L.AsIx Conway.ConwayEra
    -> Evaluate.TransactionScriptFailure Conway.ConwayEra
    -> Aeson.Value
evaluationFailureJson purpose failure =
    Aeson.object
        [ "code" .= evaluationFailureCode failure
        , "severity" .= ("error" :: T.Text)
        , "redeemer" .= purposeKey purpose
        , "message" .= evaluationFailureMessage failure
        , "predicate" .= T.pack (show failure)
        , "path" .= purposePath purpose
        ]

evaluationFailureCode
    :: Evaluate.TransactionScriptFailure Conway.ConwayEra
    -> T.Text
evaluationFailureCode = \case
    Evaluate.RedeemerPointsToUnknownScriptHash _ -> "redeemer_unknown_script"
    Evaluate.MissingScript _ _ -> "missing_script"
    Evaluate.MissingDatum _ -> "missing_datum"
    Evaluate.ValidationFailure{} -> "script_validation_failure"
    Evaluate.UnknownTxIn _ -> "unknown_tx_in"
    Evaluate.InvalidTxIn _ -> "invalid_tx_in"
    Evaluate.IncompatibleBudget _ -> "incompatible_budget"
    Evaluate.NoCostModelInLedgerState _ -> "missing_cost_model"
    Evaluate.ContextError _ -> "context_translation_error"

evaluationFailureMessage
    :: Evaluate.TransactionScriptFailure Conway.ConwayEra
    -> T.Text
evaluationFailureMessage = \case
    Evaluate.RedeemerPointsToUnknownScriptHash purpose ->
        "Redeemer points to an unknown script hash: " <> T.pack (show purpose)
    Evaluate.MissingScript purpose _ ->
        "Missing Plutus script for redeemer: " <> T.pack (show purpose)
    Evaluate.MissingDatum dataHash ->
        "Missing datum required by script evaluation: "
            <> T.pack (show dataHash)
    Evaluate.ValidationFailure _ err logs _ ->
        "Plutus script evaluation failed: "
            <> T.pack (show err)
            <> logsSummary logs
    Evaluate.UnknownTxIn txIn ->
        "Redeemer points to an input absent from the supplied UTxO: "
            <> T.pack (show txIn)
    Evaluate.InvalidTxIn txIn ->
        "Redeemer points to an input that is not Plutus locked: "
            <> T.pack (show txIn)
    Evaluate.IncompatibleBudget budget ->
        "Calculated execution budget is out of ledger bounds: "
            <> T.pack (show budget)
    Evaluate.NoCostModelInLedgerState language ->
        "No cost model was supplied for Plutus language: "
            <> T.pack (show language)
    Evaluate.ContextError err ->
        "Ledger could not translate the transaction into a Plutus context: "
            <> T.pack (show err)

logsSummary :: [T.Text] -> T.Text
logsSummary [] = ""
logsSummary logs =
    " Logs: " <> T.intercalate " | " logs

totalEvaluatedExUnits :: EvaluationRun -> Aeson.Value
totalEvaluatedExUnits evaluationRun =
    let (total, partial) =
            case evaluationRun of
                EvaluationReport report ->
                    let results = Map.elems report
                        successes =
                            [ exUnits
                            | Right (_logs, exUnits) <- results
                            ]
                    in  (mconcat successes, any isLeft results)
                EvaluationNotRun _ ->
                    (mempty, True)
    in  exUnitsTotalJson total partial
  where
    isLeft (Left _) = True
    isLeft (Right _) = False

evaluatedRedeemerCount :: EvaluationRun -> Int
evaluatedRedeemerCount (EvaluationReport report) =
    length [() | Right _ <- Map.elems report]
evaluatedRedeemerCount (EvaluationNotRun _) = 0

exUnitsJson :: ExUnits.ExUnits -> Aeson.Value
exUnitsJson (ExUnits.ExUnits memory steps) =
    Aeson.object
        [ "memory" .= T.pack (show memory)
        , "steps" .= T.pack (show steps)
        ]

exUnitsTotalJson :: ExUnits.ExUnits -> Bool -> Aeson.Value
exUnitsTotalJson (ExUnits.ExUnits memory steps) partial =
    Aeson.object
        [ "memory" .= T.pack (show memory)
        , "steps" .= T.pack (show steps)
        , "partial" .= partial
        ]

purposeKey :: L.PlutusPurpose L.AsIx Conway.ConwayEra -> T.Text
purposeKey purpose =
    purposeKind purpose <> "#" <> T.pack (show (purposeIndex purpose))

purposeKind :: L.PlutusPurpose L.AsIx Conway.ConwayEra -> T.Text
purposeKind = \case
    ConwayScripts.ConwaySpending _ -> "spend"
    ConwayScripts.ConwayMinting _ -> "mint"
    ConwayScripts.ConwayCertifying _ -> "cert"
    ConwayScripts.ConwayRewarding _ -> "withdrawal"

purposeIndex :: L.PlutusPurpose L.AsIx Conway.ConwayEra -> Word32
purposeIndex = \case
    ConwayScripts.ConwaySpending (L.AsIx ix) -> ix
    ConwayScripts.ConwayMinting (L.AsIx ix) -> ix
    ConwayScripts.ConwayCertifying (L.AsIx ix) -> ix
    ConwayScripts.ConwayRewarding (L.AsIx ix) -> ix

purposePath :: L.PlutusPurpose L.AsIx Conway.ConwayEra -> [T.Text]
purposePath purpose =
    case purpose of
        ConwayScripts.ConwaySpending _ ->
            ["body", "inputs", ix]
        ConwayScripts.ConwayMinting _ ->
            ["body", "mint"]
        ConwayScripts.ConwayCertifying _ ->
            ["body", "certificates", ix]
        ConwayScripts.ConwayRewarding _ ->
            ["body", "withdrawals", ix]
  where
    ix = "#" <> T.pack (show (purposeIndex purpose))

missingKindsFor :: T.Text -> [Aeson.Value] -> [T.Text]
missingKindsFor key missingContext =
    [ kind
    | Aeson.Object item <- missingContext
    , Just (Aeson.Array requiredFor) <-
        [KeyMap.lookup "required_for" item]
    , Aeson.String key `elem` requiredFor
    , Just (Aeson.String kind) <- [KeyMap.lookup "kind" item]
    ]

evaluationWarnings :: T.Text -> [T.Text]
evaluationWarnings "succeeded" =
    ["tx.evaluate.scripts did not mutate or return transaction CBOR."]
evaluationWarnings "failed" =
    ["tx.evaluate.scripts did not mutate or return transaction CBOR."]
evaluationWarnings "not_applicable" =
    ["Transaction has no phase-2 redeemers to evaluate."]
evaluationWarnings _ =
    []

requiredContextField
    :: T.Text
    -> T.Text
    -> T.Text
    -> (Aeson.Value -> Either T.Text a)
    -> Maybe Aeson.Value
    -> (Maybe a, [Aeson.Value], [Aeson.Value])
requiredContextField field kind message parse maybeContext =
    case maybeContext >>= lookupValue (AesonKey.fromText field) of
        Nothing ->
            ( Nothing
            ,
                [ missingContextJson
                    kind
                    message
                    ["args", "context", field]
                    ["script.evaluate"]
                ]
            , []
            )
        Just value ->
            case parse value of
                Right parsed -> (Just parsed, [], [])
                Left err ->
                    ( Nothing
                    , []
                    ,
                        [ contextErrorJson
                            ("invalid_" <> kind)
                            (message <> " " <> err)
                            ["args", "context", field]
                            (Aeson.object ["detail" .= err])
                        ]
                    )

parseNetworkValue :: Aeson.Value -> Either T.Text T.Text
parseNetworkValue (Aeson.String value) =
    case T.toLower value of
        "mainnet" -> Right "mainnet"
        "testnet" -> Right "testnet"
        _ -> Left "Expected \"mainnet\" or \"testnet\"."
parseNetworkValue _ =
    Left "Expected a string value."

parseWord64Value :: T.Text -> Aeson.Value -> Either T.Text Word64
parseWord64Value _field value@(Aeson.Number _) =
    case Aeson.fromJSON value of
        Aeson.Success n -> Right n
        Aeson.Error err -> Left (T.pack err)
parseWord64Value field (Aeson.String value) =
    case readMaybe (T.unpack value) of
        Just n -> Right n
        Nothing -> Left ("Expected " <> field <> " as an unsigned integer string.")
parseWord64Value field _ =
    Left ("Expected " <> field <> " as an unsigned integer.")

parseProtocolParametersValue
    :: Aeson.Value
    -> Either T.Text (Core.PParams Conway.ConwayEra)
parseProtocolParametersValue value =
    case Aeson.fromJSON value of
        Aeson.Success pparams -> Right pparams
        Aeson.Error err -> Left (T.pack err)

inputPolicyErrors :: T.Text -> [Aeson.Value]
inputPolicyErrors "preserve" = []
inputPolicyErrors policy =
    [ contextErrorJson
        "unsupported_input_policy"
        "tx.evaluate.scripts only supports input_policy = \"preserve\"."
        ["args", "input_policy"]
        (Aeson.object ["input_policy" .= policy])
    ]

unsupportedUtxoJsonErrors :: Maybe Aeson.Value -> [Aeson.Value]
unsupportedUtxoJsonErrors maybeContext =
    case maybeContext >>= lookupValue "utxo" of
        Nothing -> []
        Just _ ->
            [ contextErrorJson
                "unsupported_utxo_json"
                "Provider-specific UTxO JSON is not ledger evidence; supply producer transaction CBOR in context.producer_txs."
                ["args", "context", "utxo"]
                (Aeson.object [])
            ]

producerDecodeContextErrors :: ProducerContext -> [Aeson.Value]
producerDecodeContextErrors context =
    [ contextErrorJson
        "producer_tx_decode_failed"
        ("Producer transaction " <> txId <> " could not be decoded: " <> err)
        ["args", "context", "producer_txs", txId]
        (Aeson.object ["tx_id" .= txId])
    | (txId, producerTx) <- Map.toList (pcProducerTxs context)
    , Left err <- [ptDecoded producerTx]
    ]

producerTxIdContextErrors :: ProducerContext -> [Aeson.Value]
producerTxIdContextErrors context =
    [ contextErrorJson
        "producer_tx_id_mismatch"
        "Producer transaction map key does not match the decoded producer transaction id."
        ["args", "context", "producer_txs", declaredTxId]
        ( Aeson.object
            [ "declared_tx_id" .= declaredTxId
            , "actual_tx_id" .= actualTxId
            ]
        )
    | (declaredTxId, producerTx) <- Map.toList (pcProducerTxs context)
    , Right producer <- [ptDecoded producerTx]
    , let actualTxId = txIdHex (Core.txIdTx producer)
    , declaredTxId /= actualTxId
    ]

producerOutputIndexContextErrors
    :: T.Text
    -> T.Text
    -> ProducerContext
    -> [TxIn.TxIn]
    -> [Aeson.Value]
producerOutputIndexContextErrors inputKind collection context txIns =
    [ contextErrorJson
        "producer_output_index_missing"
        "Producer transaction CBOR was supplied but the referenced output index does not exist."
        ["body", collection, "#" <> T.pack (show ix)]
        ( Aeson.object
            [ "input_kind" .= inputKind
            , "tx_id" .= txInTxIdHex txIn
            , "index" .= txInIndex txIn
            , "source" .= ptSource producerTx
            ]
        )
    | (ix, txIn) <- zip [0 :: Int ..] txIns
    , Just producerTx <- [producerTxLookup context txIn]
    , Right producer <- [ptDecoded producerTx]
    , isNothing (producerOutputAt txIn producer)
    ]

missingSourceOutputContextJson
    :: T.Text
    -> T.Text
    -> Int
    -> TxIn.TxIn
    -> Aeson.Value
missingSourceOutputContextJson inputKind collection ix txIn =
    Aeson.object
        [ "kind" .= ("source_output" :: T.Text)
        , "message"
            .= ( "Supply producer transaction CBOR for the referenced transaction input."
                    :: T.Text
               )
        , "path" .= (["body", collection, "#" <> T.pack (show ix)] :: [T.Text])
        , "tx_id" .= txInTxIdHex txIn
        , "index" .= txInIndex txIn
        , "input_kind" .= inputKind
        , "required_for" .= (["script.evaluate"] :: [T.Text])
        ]

missingContextJson
    :: T.Text
    -> T.Text
    -> [T.Text]
    -> [T.Text]
    -> Aeson.Value
missingContextJson kind message path requiredFor =
    Aeson.object
        [ "kind" .= kind
        , "message" .= message
        , "path" .= path
        , "required_for" .= requiredFor
        ]

contextErrorJson
    :: T.Text
    -> T.Text
    -> [T.Text]
    -> Aeson.Value
    -> Aeson.Value
contextErrorJson code message path details =
    Aeson.object
        [ "code" .= code
        , "message" .= message
        , "path" .= path
        , "details" .= details
        ]

evaluationResolvedTxInJson
    :: T.Text
    -> T.Text
    -> ProducerContext
    -> Int
    -> TxIn.TxIn
    -> Aeson.Value
evaluationResolvedTxInJson inputKind collection context ix txIn =
    let key = txInKey txIn
        baseFields =
            [ "key" .= key
            , "tx_id" .= txInTxIdHex txIn
            , "index" .= txInIndex txIn
            , "kind" .= inputKind
            , "path" .= (["body", collection, "#" <> T.pack (show ix)] :: [T.Text])
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

evaluationContextSummaryJson
    :: T.Text
    -> ProducerContext
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> Maybe Word64
    -> Maybe Word64
    -> Bool
    -> Int
    -> Int
    -> Aeson.Value
evaluationContextSummaryJson
    inputPolicy
    context
    inputs
    referenceInputs
    missingInputs
    missingReferenceInputs
    slot
    epoch
    complete
    redeemerCount
    evaluatedRedeemers =
        let resolvedInputs =
                length inputs - length missingInputs
            resolvedReferenceInputs =
                length referenceInputs - length missingReferenceInputs
            optionalFields =
                maybeWord64Field "slot" slot
                    <> maybeWord64Field "epoch" epoch
        in  Aeson.object $
                [ "input_policy" .= inputPolicy
                , "producer_tx_count" .= Map.size (pcProducerTxs context)
                , "decoded_producer_tx_count" .= decodedProducerTxCount context
                , "producer_tx_errors" .= producerTxErrors context
                , "supplied" .= producerContextSupplied context
                , "complete" .= complete
                , "input_count" .= length inputs
                , "resolved_input_count" .= resolvedInputs
                , "missing_input_count" .= length missingInputs
                , "reference_input_count" .= length referenceInputs
                , "resolved_reference_input_count" .= resolvedReferenceInputs
                , "missing_reference_input_count" .= length missingReferenceInputs
                , "redeemer_count" .= redeemerCount
                , "evaluated_redeemer_count" .= evaluatedRedeemers
                , "unspent_status" .= ("not_checked" :: T.Text)
                , "resolution" .= fromMaybe Aeson.Null (ucResolution context)
                ]
                    <> optionalFields

maybeWord64Field
    :: AesonKey.Key -> Maybe Word64 -> [(AesonKey.Key, Aeson.Value)]
maybeWord64Field key =
    maybe [] (\value -> [key .= T.pack (show value)])
