{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Conway transaction inspector.

  Decoder-only: no signature checking, no script evaluation, no fee
  validation. The hard work (CBOR → Conway `Tx`) is delegated to the
  upstream Haskell ledger packages. Browser-facing calls use a small
  ledger-operation envelope so each UI interaction can go back through
  the ledger value instead of navigating a stale client-side JSON
  projection.
-}
module Conway.Inspector
    ( inspect
    , runLedgerOperationInput
    , InspectError (..)
    ) where

import qualified Cardano.Ledger.Address as Addr
import qualified Cardano.Ledger.Alonzo.Scripts as AlonzoScripts
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.BaseTypes as BaseTypes
import qualified Cardano.Ledger.Coin as Coin
import qualified Cardano.Ledger.Conway as Conway
import qualified Cardano.Ledger.Conway.Scripts as ConwayScripts
import Cardano.Ledger.Core (TxLevel (..))
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Credential as Credential
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Mary.Value as Mary
import qualified Cardano.Ledger.Plutus.Data as PData
import qualified Cardano.Ledger.Plutus.ExUnits as ExUnits
import qualified Cardano.Ledger.TxIn as TxIn
import Control.Monad ((>=>))
import Conway.Inspector.Common
    ( InspectError (..)
    , argsObject
    , cborHexText
    , decodeTx
    , decodeTxWithBytes
    , decodeVKeyWitness
    , keyHashHex
    , listAt
    , lookupObjectValue
    , lookupValue
    , multiAssetJson
    , safeHashHex
    , scriptHashHex
    , txIdHex
    , txInJson
    , txOutJson
    , withdrawalRowsJson
    , withdrawalsCount
    )
import Conway.Inspector.Context
    ( ProducerContext
    , contextSummaryJson
    , inputPolicyFromArgs
    , missingContextTxIns
    , producerContextFromArgs
    , producerContextSupplied
    , producerTxOutput
    , resolvedTxInJson
    )
import Conway.Inspector.Evaluation (evaluateScriptsJson)
import Conway.Inspector.Validation (validateTxJson)
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (toList)
import Data.Function ((&))
import Data.List (foldl', stripPrefix)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Typeable (Typeable)
import Data.Word (Word64)
import Lens.Micro ((%~), (^.))
import Text.Read (readMaybe)

data LedgerOperationRequest = LedgerOperationRequest
    { lorTxCbor :: T.Text
    , lorOperation :: T.Text
    , lorArgs :: Aeson.Value
    , lorPath :: [T.Text]
    }

instance Aeson.FromJSON LedgerOperationRequest where
    parseJSON = Aeson.withObject "LedgerOperationRequest" $ \o -> do
        txCbor <- o Aeson..: "tx_cbor"
        operation <- parseOperation o
        legacyPath <- o Aeson..:? "path" Aeson..!= []
        args <- o Aeson..:? "args" Aeson..!= Aeson.object []
        path <- parsePathArg args legacyPath
        pure
            LedgerOperationRequest
                { lorTxCbor = txCbor
                , lorOperation = normalizeOperation operation
                , lorArgs = args
                , lorPath = path
                }
      where
        parseOperation o = do
            maybeOp <- o Aeson..:? "op"
            case maybeOp of
                Just op -> pure op
                Nothing -> do
                    maybeMethod <- o Aeson..:? "method"
                    case maybeMethod of
                        Just method -> pure method
                        Nothing -> fail "missing required field: op"

        parsePathArg args legacyPath =
            case args of
                Aeson.Object obj ->
                    case KeyMap.lookup "path" obj of
                        Just pathValue -> Aeson.parseJSON pathValue
                        Nothing -> pure legacyPath
                _ -> pure legacyPath

        normalizeOperation "inspect" = "tx.inspect"
        normalizeOperation "browse" = "tx.browse"
        normalizeOperation "intent" = "tx.intent"
        normalizeOperation "identify" = "tx.identify"
        normalizeOperation "witness.plan" = "tx.witness.plan"
        normalizeOperation "witness.attach" = "tx.witness.attach"
        normalizeOperation "validate" = "tx.validate"
        normalizeOperation "evaluate.scripts" = "tx.evaluate.scripts"
        normalizeOperation op = op

-- | Hex → bytes → Conway tx → JSON.
inspect :: BS.ByteString -> Either InspectError Aeson.Value
inspect hexBytes = do
    tx <- decodeTx hexBytes
    pure (renderTx tx)

{- | Browser/runtime ledger operation. If stdin is not a JSON operation request,
  fall back to the legacy raw-CBOR inspection path used by CLI recipes.
-}
runLedgerOperationInput
    :: BS.ByteString -> Either InspectError Aeson.Value
runLedgerOperationInput input =
    case Aeson.eitherDecodeStrict' input of
        Right request -> runLedgerOperation request
        Left err
            | looksLikeJsonRequest input -> Left (MalformedLedgerOperation err)
            | otherwise -> inspect input

looksLikeJsonRequest :: BS.ByteString -> Bool
looksLikeJsonRequest input =
    case BS.dropWhile isJsonWhitespace input of
        bs | BS.null bs -> False
        bs -> BS.head bs == 0x7b
  where
    isJsonWhitespace c = c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d

runLedgerOperation
    :: LedgerOperationRequest -> Either InspectError Aeson.Value
runLedgerOperation request = do
    (txBytes, tx) <- decodeTxWithBytes (T.encodeUtf8 (lorTxCbor request))
    case lorOperation request of
        "tx.inspect" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "inspection" .= renderTx tx
                    , "browser" .= browserJson tx (lorPath request)
                    ]
        "tx.browse" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "browser" .= browserJson tx (lorPath request)
                    ]
        "tx.identify" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "identification" .= identifyJson txBytes tx
                    ]
        "tx.intent" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "intent" .= intentSummaryJson (lorArgs request) tx
                    ]
        "tx.witness.plan" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "witness_plan" .= witnessPlanJson (lorArgs request) tx
                    ]
        "tx.witness.attach" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    (witnessAttachmentResultFields (lorArgs request) tx)
        "tx.validate" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "validation" .= validateTxJson txBytes (lorArgs request) tx
                    ]
        "tx.evaluate.scripts" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "script_evaluation" .= evaluateScriptsJson (lorArgs request) tx
                    ]
        other -> Left (UnknownLedgerOperation other)

ledgerOperationResponse
    :: T.Text -> [(AesonKey.Key, Aeson.Value)] -> Aeson.Value
ledgerOperationResponse operation resultFields =
    Aeson.object
        [ "ledger_functional_layer"
            .= ("cardano-ledger-functional/v1" :: T.Text)
        , "op" .= operation
        , "result" .= Aeson.object resultFields
        ]

witnessAttachmentResultFields
    :: Aeson.Value
    -> L.Tx TopTx Conway.ConwayEra
    -> [(AesonKey.Key, Aeson.Value)]
witnessAttachmentResultFields args tx =
    let attachment = witnessAttachmentJson args tx
        txCborField =
            case attachment of
                Aeson.Object object ->
                    case KeyMap.lookup "tx_cbor" object of
                        Just txCbor -> ["tx_cbor" .= txCbor]
                        Nothing -> []
                _ -> []
    in  txCborField <> ["witness_attachment" .= attachment]

witnessAttachmentJson
    :: Aeson.Value
    -> L.Tx TopTx Conway.ConwayEra
    -> Aeson.Value
witnessAttachmentJson args tx =
    let body = tx ^. L.bodyTxL
    in  case decodeWitnessAttachmentArg args of
            Left errors ->
                Aeson.object
                    [ "status" .= ("rejected" :: T.Text)
                    , "tx_id" .= txIdHex (Core.txIdTx tx)
                    , "body_hash" .= txIdHex (Core.txIdTxBody body)
                    , "errors" .= errors
                    , "warnings" .= ([] :: [T.Text])
                    ]
            Right witness ->
                let existingWitnesses = tx ^. (Core.witsTxL . Core.addrTxWitsL)
                    replacedExisting = any (sameWitnessKey witness) existingWitnesses
                    nextWitnesses =
                        Set.insert
                            witness
                            (Set.filter (not . sameWitnessKey witness) existingWitnesses)
                    witnessPatchAction :: T.Text
                    witnessPatchAction
                        | replacedExisting =
                            "replaced"
                        | otherwise =
                            "inserted"
                    patchedTx =
                        tx
                            & Core.witsTxL
                                . Core.addrTxWitsL
                                %~ const nextWitnesses
                    signedTxCborHex = cborHexText patchedTx
                in  Aeson.object
                        [ "status" .= ("applied" :: T.Text)
                        , "tx_id" .= txIdHex (Core.txIdTx patchedTx)
                        , "body_hash" .= txIdHex (Core.txIdTxBody body)
                        , "tx_cbor" .= signedTxCborHex
                        , "signed_tx_cbor_hex" .= signedTxCborHex
                        , "witness_patch_action" .= witnessPatchAction
                        , "errors" .= ([] :: [Aeson.Value])
                        , "warnings" .= ([] :: [T.Text])
                        ]

decodeWitnessAttachmentArg
    :: (Typeable kr)
    => Aeson.Value
    -> Either [Aeson.Value] (Keys.WitVKey kr)
decodeWitnessAttachmentArg args =
    case argsObject args >>= lookupObjectValue "vkey_witness_cbor_hex" of
        Nothing ->
            Left
                [ witnessAttachmentErrorJson
                    "missing_vkey_witness_cbor_hex"
                    "Supply args.vkey_witness_cbor_hex as hex-encoded CBOR for a single vkey witness."
                    ["args", "vkey_witness_cbor_hex"]
                    Aeson.Null
                ]
        Just (Aeson.String witnessHex) ->
            case decodeVKeyWitness (T.encodeUtf8 witnessHex) of
                Left (MalformedHex err) ->
                    Left
                        [ witnessAttachmentErrorJson
                            "malformed_vkey_witness_cbor_hex"
                            "args.vkey_witness_cbor_hex must be valid hex."
                            ["args", "vkey_witness_cbor_hex"]
                            (Aeson.object ["detail" .= err])
                        ]
                Left (MalformedCbor err) ->
                    Left
                        [ witnessAttachmentErrorJson
                            "malformed_vkey_witness_cbor"
                            "args.vkey_witness_cbor_hex must decode as a single Shelley/Conway vkey witness."
                            ["args", "vkey_witness_cbor_hex"]
                            (Aeson.object ["detail" .= err])
                        ]
                Left other ->
                    Left
                        [ witnessAttachmentErrorJson
                            "invalid_vkey_witness_cbor_hex"
                            "args.vkey_witness_cbor_hex could not be used as a vkey witness."
                            ["args", "vkey_witness_cbor_hex"]
                            (Aeson.object ["detail" .= T.pack (show other)])
                        ]
                Right witness ->
                    Right witness
        Just value ->
            Left
                [ witnessAttachmentErrorJson
                    "invalid_vkey_witness_cbor_hex_type"
                    "args.vkey_witness_cbor_hex must be a hex string."
                    ["args", "vkey_witness_cbor_hex"]
                    (Aeson.object ["actual_type" .= jsonValueType value])
                ]

witnessAttachmentErrorJson
    :: T.Text
    -> T.Text
    -> [T.Text]
    -> Aeson.Value
    -> Aeson.Value
witnessAttachmentErrorJson code message path details =
    Aeson.object
        [ "code" .= code
        , "message" .= message
        , "path" .= path
        , "details" .= details
        ]

sameWitnessKey
    :: Keys.WitVKey leftRole
    -> Keys.WitVKey rightRole
    -> Bool
sameWitnessKey left right =
    Keys.witVKeyHash left == Keys.witVKeyHash right

jsonValueType :: Aeson.Value -> T.Text
jsonValueType = \case
    Aeson.Object _ -> "object"
    Aeson.Array _ -> "array"
    Aeson.String _ -> "string"
    Aeson.Number _ -> "number"
    Aeson.Bool _ -> "boolean"
    Aeson.Null -> "null"

browserJson
    :: L.Tx TopTx Conway.ConwayEra
    -> [T.Text]
    -> Aeson.Value
browserJson tx requestedPath =
    let root = renderTx tx
        current = valueAt root requestedPath
        path = if isNothing current then [] else requestedPath
        value = fromMaybe root current
        breadcrumbs = breadcrumbsFor path
        currentLabel = case reverse breadcrumbs of
            Aeson.Object crumb : _ ->
                case KeyMap.lookup "label" crumb of
                    Just (Aeson.String label) -> label
                    _ -> "tx"
            _ -> "tx"
        kind = kindOf value
    in  Aeson.object
            [ "valid" .= True
            , "title" .= currentLabel
            , "subtitle"
                .= if kind == "array" || kind == "object"
                    then kind <> " / " <> valueSummary value
                    else kind
            , "currentPath" .= encodePath path
            , "currentJson" .= copyText value
            , "breadcrumbs" .= breadcrumbs
            , "rows" .= browserRows path value
            ]

valueAt :: Aeson.Value -> [T.Text] -> Maybe Aeson.Value
valueAt = foldl step . Just
  where
    step Nothing _ = Nothing
    step (Just (Aeson.Object o)) key =
        KeyMap.lookup (AesonKey.fromText key) o
    step (Just (Aeson.Array a)) key = do
        ix <- pathIndex key
        listAt ix (toList a)
    step _ _ = Nothing

pathIndex :: T.Text -> Maybe Int
pathIndex =
    stripPrefix "#" . T.unpack >=> readMaybe

kindOf :: Aeson.Value -> T.Text
kindOf Aeson.Null = "null"
kindOf (Aeson.Bool _) = "boolean"
kindOf (Aeson.Number _) = "number"
kindOf (Aeson.String _) = "string"
kindOf (Aeson.Array _) = "array"
kindOf (Aeson.Object _) = "object"

valueSummary :: Aeson.Value -> T.Text
valueSummary (Aeson.Array a) =
    plural (length a) "item"
valueSummary (Aeson.Object o) =
    plural (length (KeyMap.toList o)) "field"
valueSummary (Aeson.String t) =
    shortText t
valueSummary Aeson.Null =
    "null"
valueSummary value =
    copyText value

plural :: Int -> T.Text -> T.Text
plural n label =
    T.pack (show n) <> " " <> label <> if n == 1 then "" else "s"

pluralWith :: Int -> T.Text -> T.Text -> T.Text
pluralWith n singular pluralLabel =
    T.pack (show n) <> " " <> if n == 1 then singular else pluralLabel

shortText :: T.Text -> T.Text
shortText text =
    let limit = 56
    in  if T.length text <= limit
            then text
            else T.take 40 text <> "..." <> T.takeEnd 12 text

copyText :: Aeson.Value -> T.Text
copyText (Aeson.String t) = t
copyText value =
    T.decodeUtf8 (BSL.toStrict (Aeson.encode value))

browserRows :: [T.Text] -> Aeson.Value -> [Aeson.Value]
browserRows parentPath (Aeson.Array a) =
    [ browserRow parentPath (T.pack ("#" <> show ix)) child
    | (ix, child) <- zip [0 :: Int ..] (toList a)
    ]
browserRows parentPath (Aeson.Object o) =
    [ browserRow parentPath (AesonKey.toText key) child
    | (key, child) <- KeyMap.toList o
    ]
browserRows _ _ =
    []

browserRow :: [T.Text] -> T.Text -> Aeson.Value -> Aeson.Value
browserRow parentPath label value =
    let path = parentPath <> [label]
    in  Aeson.object
            [ "label" .= label
            , "path" .= encodePath path
            , "kind" .= kindOf value
            , "summary" .= valueSummary value
            , "copyValue" .= copyText value
            , "canDive" .= isContainer value
            ]

isContainer :: Aeson.Value -> Bool
isContainer (Aeson.Array _) = True
isContainer (Aeson.Object _) = True
isContainer _ = False

breadcrumbsFor :: [T.Text] -> [Aeson.Value]
breadcrumbsFor path =
    Aeson.object
        [ "label" .= ("tx" :: T.Text)
        , "path" .= encodePath []
        ]
        : [ Aeson.object
            [ "label" .= label
            , "path" .= encodePath (take n path)
            ]
          | (n, label) <- zip [1 :: Int ..] path
          ]

encodePath :: [T.Text] -> T.Text
encodePath path =
    T.decodeUtf8 (BSL.toStrict (Aeson.encode path))

identifyJson
    :: BS.ByteString
    -> L.Tx TopTx Conway.ConwayEra
    -> Aeson.Value
identifyJson txBytes tx =
    let body = tx ^. L.bodyTxL
        wits = tx ^. Core.witsTxL
        scripts = Map.elems (wits ^. Core.scriptTxWitsL)
        (nativeScripts, plutusV1, plutusV2, plutusV3) =
            scriptWitnessCounts scripts
        inputs = toList (body ^. L.inputsTxBodyL)
        refIns = toList (body ^. L.referenceInputsTxBodyL)
        outputs = toList (body ^. L.outputsTxBodyL)
        certs = toList (body ^. L.certsTxBodyL)
        withdrawals = body ^. L.withdrawalsTxBodyL
        reqSigners = toList (body ^. L.reqSignerHashesTxBodyL)
    in  Aeson.object
            [ "era" .= ("Conway" :: T.Text)
            , "tx_id" .= txIdHex (Core.txIdTx tx)
            , "body_hash" .= txIdHex (Core.txIdTxBody body)
            , "tx_size_bytes" .= BS.length txBytes
            , "fee_lovelace" .= T.pack (show (Coin.unCoin (body ^. L.feeTxBodyL)))
            , "input_count" .= length inputs
            , "reference_input_count" .= length refIns
            , "output_count" .= length outputs
            , "cert_count" .= length certs
            , "withdrawal_count" .= withdrawalsCount withdrawals
            , "required_signer_count" .= length reqSigners
            , "witness_counts"
                .= Aeson.object
                    [ "vkey" .= Set.size (wits ^. Core.addrTxWitsL)
                    , "bootstrap" .= Set.size (wits ^. Core.bootAddrTxWitsL)
                    , "native_script" .= nativeScripts
                    , "plutus_v1" .= plutusV1
                    , "plutus_v2" .= plutusV2
                    , "plutus_v3" .= plutusV3
                    , "redeemer" .= Map.size (L.unRedeemers (wits ^. L.rdmrsTxWitsL))
                    , "datum" .= Map.size (L.unTxDats (wits ^. L.datsTxWitsL))
                    ]
            ]

intentSummaryJson
    :: Aeson.Value
    -> L.Tx TopTx Conway.ConwayEra
    -> Aeson.Value
intentSummaryJson args tx =
    let body = tx ^. L.bodyTxL
        wits = tx ^. Core.witsTxL
        context = producerContextFromArgs args
        inputPolicy = inputPolicyFromArgs args
        inputs = toList (body ^. L.inputsTxBodyL)
        referenceInputs = toList (body ^. L.referenceInputsTxBodyL)
        outputs = toList (body ^. L.outputsTxBodyL)
        certs = toList (body ^. L.certsTxBodyL)
        withdrawals = body ^. L.withdrawalsTxBodyL
        requiredSignerHexes =
            keyHashHex <$> toList (body ^. L.reqSignerHashesTxBodyL)
        presentVKeyHexes =
            keyHashHex . Keys.witVKeyHash <$> toList (wits ^. Core.addrTxWitsL)
        presentBootstrapHexes =
            keyHashHex . Keys.bootstrapWitKeyHash
                <$> toList (wits ^. Core.bootAddrTxWitsL)
        presentVKeyHexSet =
            Set.fromList presentVKeyHexes
        presentBootstrapHexSet =
            Set.fromList presentBootstrapHexes
        presentSignerHexSet =
            Set.fromList (presentVKeyHexes <> presentBootstrapHexes)
        signerHexSet =
            Set.fromList
                (requiredSignerHexes <> presentVKeyHexes <> presentBootstrapHexes)
        missingSignerHexes =
            filter (`Set.notMember` presentSignerHexSet) requiredSignerHexes
        scriptWitnesses =
            Map.toList (wits ^. Core.scriptTxWitsL)
        redeemers =
            Map.toList (L.unRedeemers (wits ^. L.rdmrsTxWitsL))
        datums =
            Map.toList (L.unTxDats (wits ^. L.datsTxWitsL))
        missingContextInputs =
            missingContextTxIns context inputs
        missingContextReferenceInputs =
            missingContextTxIns context referenceInputs
        metadataClaims =
            map metadataClaimJson (metadataEntries tx)
        outputLovelace =
            sum (txOutLovelace <$> outputs)
        resolvedInputOutputs =
            mapMaybe (producerTxOutput context) inputs
        resolvedInputLovelace =
            sum (txOutLovelace <$> resolvedInputOutputs)
        inputValueBuckets =
            txOutBucketTotals signerHexSet resolvedInputOutputs
        outputValueBuckets =
            txOutBucketTotals signerHexSet outputs
        signerInputLovelace =
            bucketLovelace SignerControlled inputValueBuckets
        signerOutputLovelace =
            bucketLovelace SignerControlled outputValueBuckets
        externalOutputLovelace =
            sum
                [ vbtLovelace totals
                | totals <- outputValueBuckets
                , vbtBucket totals /= SignerControlled
                ]
        netSignerKnown =
            producerContextSupplied context && null missingContextInputs
        netSignerLovelace =
            signerOutputLovelace - signerInputLovelace
        (mintedAssets, burnedAssets) =
            multiAssetDeltaCounts (body ^. L.mintTxBodyL)
        collateralInputs =
            toList (body ^. L.collateralInputsTxBodyL)
        signerValueRows =
            signerValueRowsJson
                netSignerKnown
                netSignerLovelace
                signerInputLovelace
                signerOutputLovelace
                externalOutputLovelace
                (bucketCount SignerControlled inputValueBuckets)
                (bucketCount SignerControlled outputValueBuckets)
                (length resolvedInputOutputs)
                (length outputs)
        requiredSignerRows =
            zipWith
                ( requiredSignerCoverageRowJson presentVKeyHexSet presentBootstrapHexSet
                )
                [0 :: Int ..]
                requiredSignerHexes
        intentEffects =
            [
                ( "Consumes inputs"
                , plural (length inputs) "input"
                , if producerContextSupplied context
                    then
                        plural (length resolvedInputOutputs) "source output"
                            <> " resolved from producer transaction CBOR"
                    else "source outputs not supplied"
                )
            ,
                ( "Creates outputs"
                , plural (length outputs) "output"
                , T.pack (show outputLovelace) <> " lovelace total across all outputs"
                )
            ,
                ( "Pays fee"
                , T.pack (show (Coin.unCoin (body ^. L.feeTxBodyL))) <> " lovelace"
                , ""
                )
            ,
                ( "Required signatures"
                , plural (length requiredSignerHexes) "signer"
                , if null missingSignerHexes
                    then "all declared signer hashes have witnesses"
                    else
                        plural (length missingSignerHexes) "declared signer"
                            <> " missing from witnesses"
                )
            ,
                ( "Scripts"
                , plural (length redeemers) "redeemer"
                , pluralWith
                    (length scriptWitnesses)
                    "script witness"
                    "script witnesses"
                )
            ,
                ( "Reference inputs"
                , plural (length referenceInputs) "read-only input"
                , "reference inputs are available to scripts but are not spent"
                )
            ,
                ( "Withdrawals"
                , plural (withdrawalsCount withdrawals) "withdrawal"
                , ""
                )
            ,
                ( "Mint/burn"
                , mintBurnLabel mintedAssets burnedAssets
                , ""
                )
            ,
                ( "Collateral"
                , plural (length collateralInputs) "collateral input"
                , collateralLabel
                    (body ^. L.totalCollateralTxBodyL)
                    (body ^. L.collateralReturnTxBodyL)
                )
            ]
        warnings =
            intentWarnings missingSignerHexes
        structuredWithdrawals =
            withdrawalRowsJson withdrawals
    in  Aeson.object
            [ "title" .= ("Signing summary" :: T.Text)
            , "subtitle"
                .= intentSubtitle metadataClaims missingSignerHexes redeemers
            , "tx_id" .= txIdHex (Core.txIdTx tx)
            , "body_hash" .= txIdHex (Core.txIdTxBody body)
            , "fee_lovelace" .= T.pack (show (Coin.unCoin (body ^. L.feeTxBodyL)))
            , "input_policy" .= inputPolicy
            , "metrics"
                .= [ metricJson "Fee" (formatLovelace (Coin.unCoin (body ^. L.feeTxBodyL)))
                   , metricJson
                        "Signer net ADA"
                        (netSignerLovelaceLabel netSignerKnown netSignerLovelace)
                   , metricJson "Output total" (formatLovelace outputLovelace)
                   , metricJson
                        "Required signers"
                        (T.pack (show (length requiredSignerHexes)))
                   , metricJson "Missing signers" $
                        if null missingSignerHexes
                            then "none"
                            else plural (length missingSignerHexes) "missing required signer"
                   , metricJson "Redeemers" (plural (length redeemers) "redeemer")
                   , metricJson
                        "Withdrawals"
                        (plural (withdrawalsCount withdrawals) "withdrawal")
                   , metricJson "Mint/burn" (mintBurnLabel mintedAssets burnedAssets)
                   ]
            , "claims" .= map metadataClaimSummaryJson (metadataEntries tx)
            , "sections"
                .= [ sectionJson
                        "Signer value perspective"
                        "No signer value perspective available."
                        signerValueRows
                   , sectionJson
                        "Critical effects"
                        "No transaction effects reported."
                        (zipWith effectRowJson [0 :: Int ..] intentEffects)
                   , sectionJson
                        "Declared required signers"
                        "No declared required signers."
                        requiredSignerRows
                   , sectionJson
                        "Missing required signers"
                        "None missing."
                        (zipWith missingSignerRowJson [0 :: Int ..] missingSignerHexes)
                   ]
            , "metadata_claims" .= metadataClaims
            , "signing"
                .= Aeson.object
                    [ "required_signer_count" .= length requiredSignerHexes
                    , "required_signers"
                        .= map
                            (requiredSignerCoverageJson presentVKeyHexSet presentBootstrapHexSet)
                            requiredSignerHexes
                    , "present_vkey_witness_count" .= length presentVKeyHexes
                    , "present_vkey_witnesses"
                        .= map presentVKeyWitnessJson presentVKeyHexes
                    , "present_bootstrap_witness_count" .= length presentBootstrapHexes
                    , "present_bootstrap_witnesses"
                        .= map presentBootstrapWitnessJson presentBootstrapHexes
                    , "missing_vkey_witness_count" .= length missingSignerHexes
                    , "missing_vkey_witnesses" .= map missingSignerJson missingSignerHexes
                    ]
            , "value"
                .= Aeson.object
                    [ "output_lovelace" .= T.pack (show outputLovelace)
                    , "resolved_input_lovelace" .= T.pack (show resolvedInputLovelace)
                    , "resolved_input_count" .= length resolvedInputOutputs
                    , "input_lovelace_complete"
                        .= (producerContextSupplied context && null missingContextInputs)
                    , "net_spend_known" .= netSignerKnown
                    , "net_spend_note" .= netSignerNote netSignerKnown
                    , "signer_lovelace"
                        .= Aeson.object
                            [ "known" .= netSignerKnown
                            , "resolved_input_lovelace" .= T.pack (show signerInputLovelace)
                            , "output_lovelace" .= T.pack (show signerOutputLovelace)
                            , "external_or_script_output_lovelace"
                                .= T.pack (show externalOutputLovelace)
                            , "net_lovelace"
                                .= if netSignerKnown
                                    then Aeson.String (T.pack (show netSignerLovelace))
                                    else Aeson.Null
                            , "basis"
                                .= ( "payment key credentials matching declared required signers or present key witnesses"
                                        :: T.Text
                                   )
                            ]
                    , "resolved_input_buckets" .= map valueBucketJson inputValueBuckets
                    , "output_buckets" .= map valueBucketJson outputValueBuckets
                    , "outputs"
                        .= zipWith
                            (curry (intentOutputJson signerHexSet))
                            [0 ..]
                            outputs
                    ]
            , "features"
                .= Aeson.object
                    [ "input_count" .= length inputs
                    , "reference_input_count" .= length referenceInputs
                    , "output_count" .= length outputs
                    , "cert_count" .= length certs
                    , "withdrawal_count" .= withdrawalsCount withdrawals
                    , "script_count" .= length scriptWitnesses
                    , "redeemer_count" .= length redeemers
                    , "datum_count" .= length datums
                    , "minted_asset_count" .= mintedAssets
                    , "burned_asset_count" .= burnedAssets
                    , "collateral_input_count" .= length collateralInputs
                    , "has_collateral_return"
                        .= hasStrictMaybe (body ^. L.collateralReturnTxBodyL)
                    , "has_total_collateral"
                        .= hasStrictMaybe (body ^. L.totalCollateralTxBodyL)
                    ]
            , "scripts" .= map (redeemerEntryJson inputs) redeemers
            , "withdrawals" .= structuredWithdrawals
            , "effects" .= map intentEffect intentEffects
            , "context"
                .= contextSummaryJson
                    inputPolicy
                    context
                    inputs
                    referenceInputs
                    missingContextInputs
                    missingContextReferenceInputs
            , "warnings" .= warnings
            ]

intentSubtitle :: [Aeson.Value] -> [T.Text] -> [a] -> T.Text
intentSubtitle metadataClaims missingSignerHexes redeemers =
    let claimCount = length metadataClaims
        signerText =
            if null missingSignerHexes
                then "required signer witnesses present"
                else plural (length missingSignerHexes) "missing required signer"
    in  plural claimCount "metadata claim"
            <> " / "
            <> signerText
            <> " / "
            <> plural (length redeemers) "redeemer"

intentWarnings
    :: [T.Text]
    -> [T.Text]
intentWarnings missingSignerHexes =
    [ "Metadata describes intent but is self-declared; verify it against the destination addresses and contract policy."
        :: T.Text
    ]
        <> [ "Declared required signer hashes are absent from the witness set."
           | not (null missingSignerHexes)
           ]

metricJson :: T.Text -> T.Text -> Aeson.Value
metricJson label value =
    Aeson.object
        [ "label" .= label
        , "value" .= value
        ]

sectionJson :: T.Text -> T.Text -> [Aeson.Value] -> Aeson.Value
sectionJson title empty rows =
    Aeson.object
        [ "title" .= title
        , "empty" .= empty
        , "rows" .= rows
        ]

effectRowJson :: Int -> (T.Text, T.Text, T.Text) -> Aeson.Value
effectRowJson index (label, value, detail) =
    rowJson
        label
        value
        (encodePath ["intent", "effects", T.pack ("#" <> show index)])
        value
        detail

missingSignerRowJson :: Int -> T.Text -> Aeson.Value
missingSignerRowJson index signerHash =
    rowJson
        "declared required signer not present in vkey or bootstrap witnesses"
        signerHash
        ( encodePath
            [ "intent"
            , "signing"
            , "missing_vkey_witnesses"
            , T.pack ("#" <> show index)
            , "hash"
            ]
        )
        signerHash
        "declared required signer not present in vkey or bootstrap witnesses"

requiredSignerCoverageRowJson
    :: Set.Set T.Text
    -> Set.Set T.Text
    -> Int
    -> T.Text
    -> Aeson.Value
requiredSignerCoverageRowJson presentVKeyHexSet presentBootstrapHexSet index signerHash =
    rowJson
        "declared required signer"
        signerHash
        ( encodePath
            [ "intent"
            , "signing"
            , "required_signers"
            , T.pack ("#" <> show index)
            , "hash"
            ]
        )
        signerHash
        ( requiredSignerCoverageDetail
            ( signerWitnessStatus
                presentVKeyHexSet
                presentBootstrapHexSet
                signerHash
            )
        )

rowJson
    :: T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> Aeson.Value
rowJson label value path copyValue detail =
    Aeson.object
        [ "label" .= label
        , "value" .= value
        , "path" .= path
        , "copyValue" .= copyValue
        , "detail" .= detail
        ]

requiredSignerCoverageJson
    :: Set.Set T.Text
    -> Set.Set T.Text
    -> T.Text
    -> Aeson.Value
requiredSignerCoverageJson presentVKeyHexSet presentBootstrapHexSet signerHash =
    Aeson.object
        [ "hash" .= signerHash
        , "source" .= ("tx_body.required_signers" :: T.Text)
        , "witness_status"
            .= signerWitnessStatus
                presentVKeyHexSet
                presentBootstrapHexSet
                signerHash
        ]

signerWitnessStatus
    :: Set.Set T.Text
    -> Set.Set T.Text
    -> T.Text
    -> T.Text
signerWitnessStatus presentVKeyHexSet presentBootstrapHexSet signerHash
    | signerHash `Set.member` presentVKeyHexSet = "present_vkey"
    | signerHash `Set.member` presentBootstrapHexSet = "present_bootstrap"
    | otherwise = "missing"

requiredSignerCoverageDetail :: T.Text -> T.Text
requiredSignerCoverageDetail "present_vkey" =
    "declared required signer already covered by a vkey witness"
requiredSignerCoverageDetail "present_bootstrap" =
    "declared required signer already covered by a bootstrap witness"
requiredSignerCoverageDetail _ =
    "declared required signer not present in vkey or bootstrap witnesses"

data ValueBucket
    = SignerControlled
    | ExternalKeyControlled
    | ScriptControlled
    | BootstrapControlled
    deriving (Eq)

data ValueBucketTotals = ValueBucketTotals
    { vbtBucket :: ValueBucket
    , vbtCount :: Int
    , vbtLovelace :: Integer
    , vbtAssetCount :: Int
    , vbtAddresses :: [T.Text]
    -- ^ Sorted, de-duplicated hex addresses contributing to this
    -- bucket. Lets consumers verify metadata-declared destinations
    -- ('Network Compliance treasury' etc.) against the actual output
    -- addresses without re-running the inspector.
    }

txOutBucketTotals
    :: Set.Set T.Text
    -> [L.TxOut Conway.ConwayEra]
    -> [ValueBucketTotals]
txOutBucketTotals signerHashes txOuts =
    filter ((> 0) . vbtCount) $
        bucketTotals <$> allValueBuckets
  where
    bucketTotals bucket =
        let matching =
                filter ((== bucket) . txOutValueBucket signerHashes) txOuts
            addrs =
                Set.toAscList
                    ( Set.fromList
                        [ txOutAddressHex out
                        | out <- matching
                        ]
                    )
        in  ValueBucketTotals
                { vbtBucket = bucket
                , vbtCount = length matching
                , vbtLovelace = sum (txOutLovelace <$> matching)
                , vbtAssetCount = sum (txOutAssetCount <$> matching)
                , vbtAddresses = addrs
                }

txOutAddressHex :: L.TxOut Conway.ConwayEra -> T.Text
txOutAddressHex txOut =
    T.decodeUtf8 (B16.encode (Addr.serialiseAddr (txOut ^. L.addrTxOutL)))

{- | One row per redeemer in @intent.scripts[]@. Captures purpose,
target description, the redeemer's own CBOR (so consumers can decode
order parameters etc.), and ex_units committed.

Targets are described with as much detail as the @AsIx@ tag allows:
spending purposes resolve through the canonical input ordering to
emit the @TxIn@; minting purposes carry the policy id; cert / vote
/ propose / reward purposes carry the index plus the type. Decoding
the typed item from the index needs the producer-tx context for
spending and the body for the others; this output gives the reader
enough to find the target without re-running the inspector.
-}
redeemerEntryJson
    :: [TxIn.TxIn]
    -> ( ConwayScripts.ConwayPlutusPurpose AlonzoScripts.AsIx Conway.ConwayEra
       , (PData.Data Conway.ConwayEra, ExUnits.ExUnits)
       )
    -> Aeson.Value
redeemerEntryJson canonicalInputs (purpose, (datum, exu)) =
    Aeson.object
        ( purposeFields
            <> [ "redeemer_cbor_hex"
                    .= T.decodeUtf8 (B16.encode (Hashes.originalBytes datum))
               ,
                   ( "ex_units_committed"
                   , Aeson.object
                        [ "memory" .= T.pack (show (ExUnits.exUnitsMem exu))
                        , "steps" .= T.pack (show (ExUnits.exUnitsSteps exu))
                        ]
                   )
               ]
        )
  where
    purposeFields = case purpose of
        ConwayScripts.ConwaySpending (AlonzoScripts.AsIx ix) ->
            [ "purpose" .= ("spending" :: T.Text)
            , "index" .= ix
            , "input"
                .= maybe Aeson.Null txInJson (listAt (fromIntegral ix) canonicalInputs)
            ]
        ConwayScripts.ConwayMinting (AlonzoScripts.AsIx ix) ->
            [ "purpose" .= ("minting" :: T.Text)
            , "index" .= ix
            ]
        ConwayScripts.ConwayCertifying (AlonzoScripts.AsIx ix) ->
            [ "purpose" .= ("certifying" :: T.Text)
            , "index" .= ix
            ]
        ConwayScripts.ConwayRewarding (AlonzoScripts.AsIx ix) ->
            [ "purpose" .= ("rewarding" :: T.Text)
            , "index" .= ix
            ]
        ConwayScripts.ConwayVoting (AlonzoScripts.AsIx ix) ->
            [ "purpose" .= ("voting" :: T.Text)
            , "index" .= ix
            ]
        ConwayScripts.ConwayProposing (AlonzoScripts.AsIx ix) ->
            [ "purpose" .= ("proposing" :: T.Text)
            , "index" .= ix
            ]

{- | Per-output detail emitted under @intent.value.outputs[]@. Adds
@index@ + @bucket@ to the existing 'txOutJson' shape so consumers can
read individual output values and datums without re-running the
inspector. Required to verify swap order parameters from the
@intent@ envelope alone.
-}
intentOutputJson
    :: Set.Set T.Text
    -> (Int, L.TxOut Conway.ConwayEra)
    -> Aeson.Value
intentOutputJson signerHashes (i, txOut) =
    case txOutJson txOut of
        Aeson.Object fields ->
            Aeson.Object
                ( fields
                    <> KeyMap.fromList
                        [ ("index", Aeson.toJSON i)
                        ,
                            ( "bucket"
                            , Aeson.String
                                (valueBucketName (txOutValueBucket signerHashes txOut))
                            )
                        ]
                )
        other -> other

allValueBuckets :: [ValueBucket]
allValueBuckets =
    [ SignerControlled
    , ExternalKeyControlled
    , ScriptControlled
    , BootstrapControlled
    ]

txOutValueBucket
    :: Set.Set T.Text
    -> L.TxOut Conway.ConwayEra
    -> ValueBucket
txOutValueBucket signerHashes txOut =
    case txOut ^. L.addrTxOutL of
        Addr.Addr _ paymentCredential _ ->
            case Credential.credKeyHash paymentCredential of
                Just paymentKeyHash
                    | keyHashHex paymentKeyHash `Set.member` signerHashes ->
                        SignerControlled
                Just _ ->
                    ExternalKeyControlled
                Nothing ->
                    ScriptControlled
        Addr.AddrBootstrap _ ->
            BootstrapControlled

txOutAssetCount :: L.TxOut Conway.ConwayEra -> Int
txOutAssetCount txOut =
    let Mary.MaryValue _ assets = txOut ^. L.valueTxOutL
    in  multiAssetClassCount assets

multiAssetClassCount :: Mary.MultiAsset -> Int
multiAssetClassCount (Mary.MultiAsset m) =
    sum
        [ length (filter (/= 0) (Map.elems assetMap))
        | assetMap <- Map.elems m
        ]

bucketLovelace :: ValueBucket -> [ValueBucketTotals] -> Integer
bucketLovelace bucket totals =
    sum [vbtLovelace total | total <- totals, vbtBucket total == bucket]

bucketCount :: ValueBucket -> [ValueBucketTotals] -> Int
bucketCount bucket totals =
    sum [vbtCount total | total <- totals, vbtBucket total == bucket]

signerValueRowsJson
    :: Bool
    -> Integer
    -> Integer
    -> Integer
    -> Integer
    -> Int
    -> Int
    -> Int
    -> Int
    -> [Aeson.Value]
signerValueRowsJson
    netKnown
    netSignerLovelace
    signerInputLovelace
    signerOutputLovelace
    externalOutputLovelace
    signerInputCount
    signerOutputCount
    resolvedInputCount
    outputCount =
        zipWith
            valuePerspectiveRowJson
            [0 :: Int ..]
            [
                ( "Net signer ADA"
                , netSignerLovelaceLabel netKnown netSignerLovelace
                , if netKnown
                    then "negative means more signer-controlled ADA leaves than returns"
                    else
                        "producer transaction CBOR must resolve every regular input before signer net can be known"
                )
            ,
                ( "Signer-controlled inputs"
                , if netKnown || resolvedInputCount > 0
                    then formatLovelace signerInputLovelace
                    else "unknown"
                , plural signerInputCount "resolved source output"
                    <> " matched signer payment key hashes out of "
                    <> plural resolvedInputCount "resolved input"
                )
            ,
                ( "Signer-controlled outputs"
                , formatLovelace signerOutputLovelace
                , plural signerOutputCount "output"
                    <> " matched signer payment key hashes out of "
                    <> plural outputCount "output"
                )
            ,
                ( "External/script outputs"
                , formatLovelace externalOutputLovelace
                , "outputs not controlled by declared or witnessed signer payment key hashes"
                )
            ]

valuePerspectiveRowJson
    :: Int -> (T.Text, T.Text, T.Text) -> Aeson.Value
valuePerspectiveRowJson index (label, value, detail) =
    rowJson
        label
        value
        ( encodePath
            ["intent", "value", "signer_perspective", T.pack ("#" <> show index)]
        )
        value
        detail

netSignerLovelaceLabel :: Bool -> Integer -> T.Text
netSignerLovelaceLabel False _ = "unknown"
netSignerLovelaceLabel True lovelace = formatSignedLovelace lovelace

formatSignedLovelace :: Integer -> T.Text
formatSignedLovelace lovelace
    | lovelace > 0 = "+" <> formatLovelace lovelace
    | lovelace < 0 = "-" <> formatLovelace (abs lovelace)
    | otherwise = "0 ADA"

netSignerNote :: Bool -> T.Text
netSignerNote True =
    "Signer net is computed from resolved input TxOuts and output payment credentials matching declared or witnessed signer key hashes."
netSignerNote False =
    "Signer net is unknown until producer transaction CBOR resolves every regular input; output totals are still ledger facts."

valueBucketJson :: ValueBucketTotals -> Aeson.Value
valueBucketJson totals =
    Aeson.object
        [ "bucket" .= valueBucketName (vbtBucket totals)
        , "label" .= valueBucketLabel (vbtBucket totals)
        , "tx_out_count" .= vbtCount totals
        , "lovelace" .= T.pack (show (vbtLovelace totals))
        , "asset_class_count" .= vbtAssetCount totals
        , "addresses" .= vbtAddresses totals
        ]

valueBucketName :: ValueBucket -> T.Text
valueBucketName SignerControlled = "signer_controlled"
valueBucketName ExternalKeyControlled = "external_key"
valueBucketName ScriptControlled = "script"
valueBucketName BootstrapControlled = "bootstrap"

valueBucketLabel :: ValueBucket -> T.Text
valueBucketLabel SignerControlled = "Signer-controlled"
valueBucketLabel ExternalKeyControlled = "External key"
valueBucketLabel ScriptControlled = "Script"
valueBucketLabel BootstrapControlled = "Bootstrap"

intentEffect :: (T.Text, T.Text, T.Text) -> Aeson.Value
intentEffect (label, value, detail) =
    Aeson.object
        [ "label" .= label
        , "value" .= value
        , "detail" .= detail
        ]

formatLovelace :: Integer -> T.Text
formatLovelace lovelace =
    let (ada, fractional) = lovelace `quotRem` 1000000
        fractionText =
            T.dropWhileEnd
                (== '0')
                (T.justifyRight 6 '0' (T.pack (show (abs fractional))))
    in  if fractional == 0
            then T.pack (show ada) <> " ADA"
            else T.pack (show ada) <> "." <> fractionText <> " ADA"

txOutLovelace :: L.TxOut Conway.ConwayEra -> Integer
txOutLovelace txOut =
    let Mary.MaryValue c _ = txOut ^. L.valueTxOutL
    in  Coin.unCoin c

multiAssetDeltaCounts :: Mary.MultiAsset -> (Int, Int)
multiAssetDeltaCounts (Mary.MultiAsset m) =
    foldl' countPolicy (0, 0) (Map.elems m)
  where
    countPolicy (minted, burned) assets =
        foldl' countQuantity (minted, burned) (Map.elems assets)
    countQuantity (minted, burned) q
        | q > 0 = (minted + 1, burned)
        | q < 0 = (minted, burned + 1)
        | otherwise = (minted, burned)

mintBurnLabel :: Int -> Int -> T.Text
mintBurnLabel 0 0 = "No mint/burn"
mintBurnLabel minted 0 = plural minted "minted asset"
mintBurnLabel 0 burned = plural burned "burned asset"
mintBurnLabel minted burned =
    plural minted "minted asset" <> " / " <> plural burned "burned asset"

collateralLabel
    :: BaseTypes.StrictMaybe Coin.Coin
    -> BaseTypes.StrictMaybe (L.TxOut Conway.ConwayEra)
    -> T.Text
collateralLabel totalCollateral collateralReturn =
    let totalText = case totalCollateral of
            BaseTypes.SNothing -> ""
            BaseTypes.SJust coin ->
                "total " <> T.pack (show (Coin.unCoin coin)) <> " lovelace"
        returnText = case collateralReturn of
            BaseTypes.SNothing -> ""
            BaseTypes.SJust txOut ->
                "return " <> T.pack (show (txOutLovelace txOut)) <> " lovelace"
    in  case filter (not . T.null) [totalText, returnText] of
            [] -> ""
            parts -> T.intercalate " / " parts

hasStrictMaybe :: BaseTypes.StrictMaybe a -> Bool
hasStrictMaybe BaseTypes.SNothing = False
hasStrictMaybe (BaseTypes.SJust _) = True

metadataEntries
    :: L.Tx TopTx Conway.ConwayEra -> [(Word64, L.Metadatum)]
metadataEntries tx =
    case tx ^. L.auxDataTxL of
        BaseTypes.SNothing -> []
        BaseTypes.SJust auxData ->
            Map.toList (auxData ^. L.metadataTxAuxDataL)

metadataClaimSummaryJson :: (Word64, L.Metadatum) -> Aeson.Value
metadataClaimSummaryJson (label, datum) =
    let title =
            fromMaybe
                ("Metadata " <> T.pack (show label))
                (metadataTextAt ["label"] datum)
        value =
            fromMaybe
                (fromMaybe "" (metadataTextAt ["event"] datum))
                (metadataTextAt ["description"] datum)
        detail =
            T.intercalate
                " / "
                ( filter
                    (not . T.null)
                    [ fromMaybe "" (metadataTextAt ["justification"] datum)
                    , maybePrefix
                        "destination "
                        (metadataTextAt ["destination", "label"] datum)
                    , "metadata label " <> T.pack (show label)
                    , "self-declared"
                    ]
                )
    in  Aeson.object
            [ "label" .= title
            , "value" .= value
            , "detail" .= detail
            ]

maybePrefix :: T.Text -> Maybe T.Text -> T.Text
maybePrefix _ Nothing = ""
maybePrefix prefix (Just value) = prefix <> value

metadataClaimJson :: (Word64, L.Metadatum) -> Aeson.Value
metadataClaimJson (label, datum) =
    let title = metadataTextAt ["label"] datum
        event = metadataTextAt ["event"] datum
        description = metadataTextAt ["description"] datum
        destination = metadataTextAt ["destination", "label"] datum
        justification = metadataTextAt ["justification"] datum
        context = metadataTextAt ["context"] datum
        hashValue = metadataTextAt ["hash"] datum
        hashAlgorithm = metadataTextAt ["hashAlgorithm"] datum
    in  Aeson.object
            [ "label" .= T.pack (show label)
            , "self_declared" .= True
            , "title" .= fromMaybe "" title
            , "event" .= fromMaybe "" event
            , "description" .= fromMaybe "" description
            , "destination" .= fromMaybe "" destination
            , "justification" .= fromMaybe "" justification
            , "context" .= fromMaybe "" context
            , "hash" .= fromMaybe "" hashValue
            , "hash_algorithm" .= fromMaybe "" hashAlgorithm
            , "value" .= metadatumJson datum
            ]

metadataTextAt :: [T.Text] -> L.Metadatum -> Maybe T.Text
metadataTextAt [] datum = metadataText datum
metadataTextAt path datum =
    case metadataTextAtDirect path datum of
        Just value -> Just value
        Nothing -> firstJust (metadataTextAt path <$> metadataChildren datum)

metadataTextAtDirect :: [T.Text] -> L.Metadatum -> Maybe T.Text
metadataTextAtDirect [] datum = metadataText datum
metadataTextAtDirect (key : rest) datum = do
    fields <- metadataTextMap datum
    child <- lookup key fields
    metadataTextAtDirect rest child

metadataChildren :: L.Metadatum -> [L.Metadatum]
metadataChildren (L.Map entries) = snd <$> entries
metadataChildren (L.List items) = items
metadataChildren _ = []

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

metadataText :: L.Metadatum -> Maybe T.Text
metadataText (L.S textValue) = Just textValue
metadataText (L.List items) =
    let pieces = mapMaybe metadataText items
    in  if null pieces then Nothing else Just (T.intercalate " " pieces)
metadataText _ = Nothing

metadataTextMap :: L.Metadatum -> Maybe [(T.Text, L.Metadatum)]
metadataTextMap (L.Map entries) =
    traverse textKey entries
  where
    textKey (L.S key, value) = Just (key, value)
    textKey _ = Nothing
metadataTextMap _ = Nothing

metadatumJson :: L.Metadatum -> Aeson.Value
metadatumJson (L.I n) = Aeson.toJSON (T.pack (show n))
metadatumJson (L.B bytes) =
    Aeson.String (T.decodeUtf8 (B16.encode bytes))
metadatumJson (L.S textValue) =
    Aeson.String textValue
metadatumJson (L.List values) =
    Aeson.toJSON (metadatumJson <$> values)
metadatumJson datum@(L.Map entries) =
    case metadataTextMap datum of
        Just textEntries ->
            Aeson.object
                [ AesonKey.fromText key .= metadatumJson value
                | (key, value) <- textEntries
                ]
        Nothing ->
            Aeson.toJSON
                [ Aeson.object
                    [ "key" .= metadatumJson key
                    , "value" .= metadatumJson value
                    ]
                | (key, value) <- entries
                ]

witnessPlanJson
    :: Aeson.Value
    -> L.Tx TopTx Conway.ConwayEra
    -> Aeson.Value
witnessPlanJson args tx =
    let body = tx ^. L.bodyTxL
        wits = tx ^. Core.witsTxL
        context = producerContextFromArgs args
        inputPolicy = inputPolicyFromArgs args
        inputs = toList (body ^. L.inputsTxBodyL)
        referenceInputs =
            toList (body ^. L.referenceInputsTxBodyL)
        requiredSignerHexes =
            keyHashHex <$> toList (body ^. L.reqSignerHashesTxBodyL)
        presentVKeyHexes =
            keyHashHex . Keys.witVKeyHash <$> toList (wits ^. Core.addrTxWitsL)
        presentBootstrapHexes =
            keyHashHex . Keys.bootstrapWitKeyHash
                <$> toList (wits ^. Core.bootAddrTxWitsL)
        presentSignerHexSet =
            Set.fromList (presentVKeyHexes <> presentBootstrapHexes)
        missingSignerHexes =
            filter (`Set.notMember` presentSignerHexSet) requiredSignerHexes
        scriptWitnesses =
            Map.toList (wits ^. Core.scriptTxWitsL)
        redeemers =
            Map.toList (L.unRedeemers (wits ^. L.rdmrsTxWitsL))
        datums =
            Map.toList (L.unTxDats (wits ^. L.datsTxWitsL))
        missingContextInputs =
            missingContextTxIns context inputs
        missingContextReferenceInputs =
            missingContextTxIns context referenceInputs
        warnings =
            contextWarnings
                context
                missingContextInputs
                missingContextReferenceInputs
                : [ "Declared required signer hashes are absent from the witness set."
                        :: T.Text
                  | not (null missingSignerHexes)
                  ]
    in  Aeson.object
            [ "required_signers" .= map requiredSignerJson requiredSignerHexes
            , "present_vkey_witnesses"
                .= map presentVKeyWitnessJson presentVKeyHexes
            , "present_bootstrap_witnesses"
                .= map presentBootstrapWitnessJson presentBootstrapHexes
            , "missing_vkey_witnesses"
                .= map missingSignerJson missingSignerHexes
            , "scripts" .= map scriptWitnessJson scriptWitnesses
            , "redeemers" .= map redeemerJson redeemers
            , "datums" .= map datumWitnessJson datums
            , "reference_inputs" .= map txInJson referenceInputs
            , "resolved_inputs"
                .= map (resolvedTxInJson context) inputs
            , "resolved_reference_inputs"
                .= map (resolvedTxInJson context) referenceInputs
            , "context"
                .= contextSummaryJson
                    inputPolicy
                    context
                    inputs
                    referenceInputs
                    missingContextInputs
                    missingContextReferenceInputs
            , "summary"
                .= Aeson.object
                    [ "required_signer_count" .= length requiredSignerHexes
                    , "present_vkey_witness_count" .= length presentVKeyHexes
                    , "present_bootstrap_witness_count" .= length presentBootstrapHexes
                    , "missing_vkey_witness_count" .= length missingSignerHexes
                    , "script_count" .= length scriptWitnesses
                    , "redeemer_count" .= length redeemers
                    , "datum_count" .= length datums
                    , "reference_input_count" .= length referenceInputs
                    ]
            , "warnings" .= warnings
            ]

transactionOnlyWitnessPlanWarning :: T.Text
transactionOnlyWitnessPlanWarning =
    "Transaction-only witness plan: producer transaction CBOR was not supplied, so input address credentials, reference scripts, and datum requirements cannot be inferred."

partialProducerContextWarning :: T.Text
partialProducerContextWarning =
    "Producer transaction context was supplied but does not resolve every transaction input."

completeProducerContextWarning :: T.Text
completeProducerContextWarning =
    "Producer transaction CBOR resolved every visible transaction input; live unspent status is not checked by this operation."

contextWarnings
    :: ProducerContext
    -> [TxIn.TxIn]
    -> [TxIn.TxIn]
    -> T.Text
contextWarnings context missingInputs missingReferenceInputs
    | not (producerContextSupplied context) =
        transactionOnlyWitnessPlanWarning
    | null missingInputs && null missingReferenceInputs =
        completeProducerContextWarning
    | otherwise = partialProducerContextWarning

requiredSignerJson :: T.Text -> Aeson.Value
requiredSignerJson signerHash =
    Aeson.object
        [ "hash" .= signerHash
        , "source" .= ("tx_body.required_signers" :: T.Text)
        ]

presentVKeyWitnessJson :: T.Text -> Aeson.Value
presentVKeyWitnessJson signerHash =
    Aeson.object
        [ "hash" .= signerHash
        , "source" .= ("witness_set.vkey" :: T.Text)
        ]

presentBootstrapWitnessJson :: T.Text -> Aeson.Value
presentBootstrapWitnessJson signerHash =
    Aeson.object
        [ "hash" .= signerHash
        , "source" .= ("witness_set.bootstrap" :: T.Text)
        ]

missingSignerJson :: T.Text -> Aeson.Value
missingSignerJson signerHash =
    Aeson.object
        [ "hash" .= signerHash
        , "reason"
            .= ( "declared required signer not present in vkey or bootstrap witnesses"
                    :: T.Text
               )
        ]

scriptWitnessJson
    :: (Hashes.ScriptHash, ConwayScripts.AlonzoScript Conway.ConwayEra)
    -> Aeson.Value
scriptWitnessJson (scriptHash, script) =
    Aeson.object
        [ "hash" .= scriptHashHex scriptHash
        , "language" .= scriptWitnessLanguage script
        , "source" .= ("witness_set.scripts" :: T.Text)
        ]

scriptWitnessLanguage
    :: ConwayScripts.AlonzoScript Conway.ConwayEra
    -> T.Text
scriptWitnessLanguage = \case
    ConwayScripts.NativeScript _ -> "native_script"
    ConwayScripts.PlutusScript plutusScript ->
        case plutusScript of
            ConwayScripts.ConwayPlutusV1 _ -> "plutus_v1"
            ConwayScripts.ConwayPlutusV2 _ -> "plutus_v2"
            ConwayScripts.ConwayPlutusV3 _ -> "plutus_v3"

redeemerJson
    :: ( L.PlutusPurpose L.AsIx Conway.ConwayEra
       , (PData.Data Conway.ConwayEra, ExUnits.ExUnits)
       )
    -> Aeson.Value
redeemerJson (purpose, (redeemerData, exUnits)) =
    Aeson.object
        [ "purpose" .= T.pack (show purpose)
        , "redeemer_data_hash" .= safeHashHex (PData.hashData redeemerData)
        , "ex_units" .= Aeson.toJSON exUnits
        ]

datumWitnessJson
    :: (Hashes.DataHash, PData.Data Conway.ConwayEra)
    -> Aeson.Value
datumWitnessJson (dataHash, datumValue) =
    Aeson.object
        [ "hash" .= safeHashHex dataHash
        , "computed_hash" .= safeHashHex (PData.hashData datumValue)
        , "source" .= ("witness_set.datums" :: T.Text)
        ]

scriptWitnessCounts
    :: [ConwayScripts.AlonzoScript Conway.ConwayEra]
    -> (Int, Int, Int, Int)
scriptWitnessCounts =
    foldl' step (0, 0, 0, 0)
  where
    step (nativeN, v1N, v2N, v3N) = \case
        ConwayScripts.NativeScript _ ->
            (nativeN + 1, v1N, v2N, v3N)
        ConwayScripts.PlutusScript plutusScript ->
            case plutusScript of
                ConwayScripts.ConwayPlutusV1 _ ->
                    (nativeN, v1N + 1, v2N, v3N)
                ConwayScripts.ConwayPlutusV2 _ ->
                    (nativeN, v1N, v2N + 1, v3N)
                ConwayScripts.ConwayPlutusV3 _ ->
                    (nativeN, v1N, v2N, v3N + 1)

renderTx :: L.Tx TopTx Conway.ConwayEra -> Aeson.Value
renderTx tx =
    let body = tx ^. L.bodyTxL
        inputs = toList (body ^. L.inputsTxBodyL)
        refIns = toList (body ^. L.referenceInputsTxBodyL)
        outputs = toList (body ^. L.outputsTxBodyL)
        fee = body ^. L.feeTxBodyL
        vldt = body ^. L.vldtTxBodyL
        mint = body ^. L.mintTxBodyL
        certs = toList (body ^. L.certsTxBodyL)
        withdrawals = body ^. L.withdrawalsTxBodyL
        reqSigners = toList (body ^. L.reqSignerHashesTxBodyL)
    in  Aeson.Object $
            KeyMap.fromList
                [ "era" .= ("Conway" :: T.Text)
                , "decoder"
                    .= ( "cardano-ledger-conway + cardano-ledger-binary (wasm32-wasi, GHC 9.12)"
                            :: T.Text
                       )
                , "fee_lovelace" .= T.pack (show (Coin.unCoin fee))
                , "validity_interval" .= validityJson vldt
                , "input_count" .= length inputs
                , "reference_input_count" .= length refIns
                , "output_count" .= length outputs
                , "cert_count" .= length certs
                , "withdrawal_count" .= withdrawalsCount withdrawals
                , "required_signer_count" .= length reqSigners
                , "inputs" .= map txInJson inputs
                , "reference_inputs" .= map txInJson refIns
                , "outputs" .= map txOutJson outputs
                , "mint" .= multiAssetJson mint
                ]

validityJson :: L.ValidityInterval -> Aeson.Value
validityJson (L.ValidityInterval before hereafter) =
    Aeson.object
        [ "invalid_before" .= renderSlot before
        , "invalid_hereafter" .= renderSlot hereafter
        ]
  where
    renderSlot :: BaseTypes.StrictMaybe BaseTypes.SlotNo -> Aeson.Value
    renderSlot BaseTypes.SNothing = Aeson.Null
    renderSlot (BaseTypes.SJust s) = Aeson.toJSON (T.pack (show (BaseTypes.unSlotNo s)))
