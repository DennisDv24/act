{-# LANGUAGE RecordWildCards #-}
{-# Language GADTs #-}
{-# Language OverloadedStrings #-}
{-# Language ScopedTypeVariables #-}
{-# Language TypeApplications #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE OverloadedLists #-}

module K where

import Prelude hiding (GT, LT)

import Syntax
import Syntax.Annotated hiding (SlotType(..))

import Error
import Data.Text (Text, pack, unpack)
import Data.List hiding (group)
import Data.Maybe
import qualified Data.Text as Text
import EVM.Types hiding (Expr(..))

import EVM.Solidity (SolcContract(..), StorageItem(..), SlotType(..))
import Data.Map.Strict (Map) -- abandon in favor of [(a,b)]?
import qualified Data.Map.Strict as Map -- abandon in favor of [(a,b)]?

-- Transforms a RefinedSyntax.Behaviour
-- to a k spec.

type Err = Error String

cell :: String -> String -> String
cell key value = "<" <> key <> "> " <> value <> " </" <> key <> "> \n"

(|-) :: String -> String -> String
(|-) = cell

infix 7 |-

type KSpec = String

getContractName :: Text -> String
getContractName = unpack . Text.concat . Data.List.tail . Text.splitOn ":"

data KOptions =
  KOptions {
    gasExprs :: Map Id String,
    storage :: Maybe String,
    extractbin :: Bool
    }

makekSpec :: Map Text SolcContract -> KOptions -> Behaviour -> Err (String, String)
makekSpec sources _ behaviour =
  let this = _contract behaviour
      names = Map.fromList $ fmap (\(a, b) -> (getContractName a, b)) (Map.toList sources)
      hasLayout = Map.foldr ((&&) . isJust . (\ SolcContract{..} -> storageLayout)) True sources
  in
    if hasLayout then do
      thisSource <- validate
        [(nowhere, unlines ["Bytecode not found for:", show this, "Sources available:", show $ Map.keys sources])]
        (Map.lookup this) names
      pure $ mkTerm thisSource names behaviour

    else throw (nowhere, "No storagelayout found")

kCalldata :: Interface -> String
kCalldata (Interface a args) =
  "#abiCallData("
  <> show a <> ", "
  <> if null args then ".IntList"
     else intercalate ", " (fmap (\(Decl typ varname) -> "#" <> show typ <> "(" <> kVar varname <> ")") args)
  <> ")"

kStorageName :: When -> TStorageItem a -> String
kStorageName t item = kVar (idFromItem item) <> "-" <> show t
                   <> intercalate "_" ("" : fmap kTypedExpr (ixsFromItem item))

kVar :: Id -> String
kVar a = (unpack . Text.toUpper . pack $ [head a]) <> tail a

kAbiEncode :: Maybe TypedExp -> String
kAbiEncode Nothing = ".ByteArray"
kAbiEncode (Just (TExp SInteger a)) = "#enc(#uint256" <> kExpr a <> ")"
kAbiEncode (Just (TExp SBoolean _)) = ".ByteArray"
kAbiEncode (Just (TExp SByteStr _)) = ".ByteArray"
kAbiEncode (Just (TExp SContract _)) = error "contracts not supported"

kTypedExpr :: TypedExp -> String
kTypedExpr (TExp SInteger a) = kExpr a
kTypedExpr (TExp SBoolean a) = kExpr a
kTypedExpr (TExp SByteStr _) = error "TODO: add support for TExp SByteStr to kExpr"
kTypedExpr (TExp SContract _) = error "contracts not supported"

kExpr :: Exp a -> String
-- integers
kExpr (Add _ a b) = "(" <> kExpr a <> " +Int " <> kExpr b <> ")"
kExpr (Sub _ a b) = "(" <> kExpr a <> " -Int " <> kExpr b <> ")"
kExpr (Mul _ a b) = "(" <> kExpr a <> " *Int " <> kExpr b <> ")"
kExpr (Div _ a b) = "(" <> kExpr a <> " /Int " <> kExpr b <> ")"
kExpr (Mod _ a b) = "(" <> kExpr a <> " modInt " <> kExpr b <> ")"
kExpr (Exp _ a b) = "(" <> kExpr a <> " ^Int " <> kExpr b <> ")"
kExpr (LitInt _ a) = show a
kExpr (IntMin p a) = kExpr $ LitInt p $ negate $ 2 ^ (a - 1)
kExpr (IntMax p a) = kExpr $ LitInt p $ 2 ^ (a - 1) - 1
kExpr (UIntMin p _) = kExpr $ LitInt p 0
kExpr (UIntMax p a) = kExpr $ LitInt p $ 2 ^ a - 1
kExpr (IntEnv _ a) = show a

-- booleans
kExpr (And _ a b) = "(" <> kExpr a <> " andBool\n " <> kExpr b <> ")"
kExpr (Or _ a b) = "(" <> kExpr a <> " orBool " <> kExpr b <> ")"
kExpr (Impl _ a b) = "(" <> kExpr a <> " impliesBool " <> kExpr b <> ")"
kExpr (Neg _ a) = "notBool (" <> kExpr a <> ")"
kExpr (LT _ a b) = "(" <> kExpr a <> " <Int " <> kExpr b <> ")"
kExpr (LEQ _ a b) = "(" <> kExpr a <> " <=Int " <> kExpr b <> ")"
kExpr (GT _ a b) = "(" <> kExpr a <> " >Int " <> kExpr b <> ")"
kExpr (GEQ _ a b) = "(" <> kExpr a <> " >=Int " <> kExpr b <> ")"
kExpr (LitBool _ a) = show a
kExpr (NEq p t a b) = "notBool (" <> kExpr (Eq p t a b) <> ")"
kExpr (Eq _ t a b) =
  let eqK typ = "(" <> kExpr a <> " ==" <> typ <> " " <> kExpr b <> ")"
  in case t of
       SInteger -> eqK "Int"
       SBoolean -> eqK "Bool"
       SByteStr -> eqK "K"
       SContract -> error "contracts not supported"

-- bytestrings
kExpr (ByStr _ str) = show str
kExpr (ByLit _ bs) = show bs
kExpr (TEntry _ t item) = kStorageName t item
kExpr (Var _ _ _ a) = kVar a
kExpr v = error ("Internal error: TODO kExpr of " <> show v)
--kExpr (Cat a b) =
--kExpr (Slice a start end) =
--kExpr (ByEnv env) =

fst' :: (a, b, c) -> a
fst' (x, _, _) = x

snd' :: (a, b, c) -> b
snd' (_, y, _) = y

trd' :: (a, b, c) -> c
trd' (_, _, z) = z

kStorageEntry :: Map Text StorageItem -> Rewrite -> (String, (Int, String, String))
kStorageEntry storageLayout update =
  let (loc, offset) = kSlot update $
        fromMaybe
         (error "Internal error: storageVar not found, please report this error")
         (Map.lookup (pack (idFromRewrite update)) storageLayout)
  in case update of
       Rewrite (Update _ a b) -> (loc, (offset, kStorageName Pre a, kExpr b))
       Constant (Loc SInteger a) -> (loc, (offset, kStorageName Pre a, kStorageName Pre a))
       v -> error $ "Internal error: TODO kStorageEntry: " <> show v -- TODO should this really be separate?

--packs entries packed in one slot
normalize :: Bool -> [(String, (Int, String, String))] -> String
normalize pass entries = foldr (\a acc -> case a of
                                 (loc, [(_, pre, post)]) ->
                                   loc <> " |-> (" <> pre
                                       <> " => " <> (if pass then post else "_") <> ")\n"
                                       <> acc
                                 (loc, items) -> let (offsets, pres, posts) = unzip3 items
                                                 in loc <> " |-> ( #packWords("
                                                        <> showSList (fmap show offsets) <> ", "
                                                        <> showSList pres <> ") "
                                                        <> " => " <> (if pass
                                                                     then "#packWords("
                                                                       <> showSList (fmap show offsets)
                                                                       <> ", " <> showSList posts <> ")"
                                                                     else "_")
                                                        <> ")\n"
                                                        <> acc
                               )
                               "\n" (group entries)
  where group :: [(String, (Int, String, String))] -> [(String, [(Int, String, String)])]
        group a = Map.toList (foldr (\(slot, (offset, pre, post)) acc -> Map.insertWith (<>) slot [(offset, pre, post)] acc) mempty a)
        showSList :: [String] -> String
        showSList = unwords

kSlot :: Rewrite -> StorageItem -> (String, Int)
kSlot update StorageItem{..} = case slotType of
  (StorageValue _) -> (show slot, offset)
  (StorageMapping _ _) -> if null (ixsFromRewrite update)
    then error $ "internal error: kSlot. Please report: " <> show update
    else ( "#hashedLocation(\"Solidity\", "
             <> show slot <> ", " <> unwords (kTypedExpr <$> ixsFromRewrite update) <> ")"
         , offset )

kAccount :: Bool -> Id -> SolcContract -> [Rewrite] -> String
kAccount pass name SolcContract{..} updates =
  "account" |- ("\n"
   <> "acctID" |- kVar name
   <> "balance" |- (kVar name <> "_balance") -- needs to be constrained to uint256
   <> "code" |- (kByteStack runtimeCode)
   <> "storage" |- (normalize pass ( fmap (kStorageEntry (fromJust storageLayout)) updates) <> "\n.Map")
   <> "origStorage" |- ".Map" -- need to be generalized once "kStorageEntry" is implemented
   <> "nonce" |- "_"
      )

kByteStack :: ByteString -> String
kByteStack bs = "#parseByteStack(\"" <> show (ByteStringS bs) <> "\")"

defaultConditions :: String -> String
defaultConditions acct_id =
    "#rangeAddress(" <> acct_id <> ")\n" <>
    "andBool " <> acct_id <> " =/=Int 0\n" <>
    "andBool " <> acct_id <> " >Int 9\n" <>
    "andBool #rangeAddress( " <> show Caller <> ")\n" <>
    "andBool #rangeAddress( " <> show Origin <> ")\n" <>
    "andBool #rangeUInt(256, " <> show  Timestamp <> ")\n" <>
    -- "andBool #rangeUInt(256, ECREC_BAL)" <>
    -- "andBool #rangeUInt(256, SHA256_BAL)" <>
    -- "andBool #rangeUInt(256, RIP160_BAL)" <>
    -- "andBool #rangeUInt(256, ID_BAL)" <>
    -- "andBool #rangeUInt(256, MODEXP_BAL)" <>
    -- "andBool #rangeUInt(256, ECADD_BAL)" <>
    -- "andBool #rangeUInt(256, ECMUL_BAL)" <>
    -- "andBool #rangeUInt(256, ECPAIRING_BAL)" <>
    "andBool " <> show Calldepth <> " <=Int 1024\n" <>
    "andBool #rangeUInt(256, " <> show Callvalue <> ")\n" <>
    "andBool #rangeUInt(256, " <> show Chainid <>  " )\n"

indent :: Int -> String -> String
indent n text = unlines $ ((Data.List.replicate n ' ') <>) <$> (lines text)

mkTerm :: SolcContract -> Map Id SolcContract -> Behaviour -> (String, String)
mkTerm SolcContract{..} accounts Behaviour{..} = (name, term)
  where code = runtimeCode
        pass = True
        repl '_' = '.'
        repl  c  = c
        name = _contract <> "_" <> _name
        term =  "rule [" <> (fmap repl name) <> "]:\n"
             <> "k" |- "#execute => #halt"
             <> "exit-code" |- "1"
             <> "mode" |- "NORMAL"
             <> "schedule" |- "ISTANBUL"
             <> "evm" |- indent 2 ("\n"
                  <> "output" |- kAbiEncode _returns
                  <> "statusCode" |- "EVMC_SUCCESS" 
                  <> "callStack" |- "CallStack"
                  <> "interimStates" |- "_"
                  <> "touchedAccounts" |- "_"
                  <> "callState" |- indent 2 ("\n"
                     <> "program" |- kByteStack code
                     <> "jumpDests" |- ("#computeValidJumpDests(" <> kByteStack code <> ")")
                     <> "id" |- kVar _contract
                     <> "caller" |- (show Caller)
                     <> "callData" |- kCalldata _interface
                     <> "callValue" |- (show Callvalue)
                        -- the following are set to the values they have
                        -- at the beginning of a CALL. They can take a
                        -- more general value in "internal" specs.
                     <> "wordStack" |- ".WordStack => _"
                     <> "localMem"  |- ".Map => _"
                     <> "pc" |- "0 => _"
                     <> "gas" |- "300000 => _" -- can be generalized in the future
                     <> "memoryUsed" |- "0 => _"
                     <> "callGas" |- "_ => _"
                     <> "static" |- "false" -- TODO: generalize
                     <> "callDepth" |- (show Calldepth)
                     )
                  <> "substate" |- indent 2 ("\n"
                      <> "selfDestruct" |- "_ => _"
                      <> "log" |- "_ => _" --TODO: spec logs?
                      <> "refund" |- "_ => _"
                      )
                  <> "gasPrice" |- "_" --could be environment var
                  <> "origin" |- show Origin
                  <> "blockhashes" |- "_"
                  <> "block" |- indent 2 ("\n"
                     <> "previousHash" |- "_"
                     <> "ommersHash" |- "_"
                     <> "coinbase" |- (show Coinbase)
                     <> "stateRoot" |- "_"
                     <> "transactionsRoot" |- "_"
                     <> "receiptsRoot" |- "_"
                     <> "logsBloom" |- "_"
                     <> "difficulty" |- (show Difficulty)
                     <> "number" |- (show Blocknumber)
                     <> "gasLimit" |- "_"
                     <> "gasUsed" |- "_"
                     <> "timestamp" |- (show Timestamp)
                     <> "extraData" |- "_"
                     <> "mixHash" |- "_"
                     <> "blockNonce" |- "_"
                     <> "ommerBlockHeaders" |- "_"
                     )
                )
                <> "network" |- indent 2 ("\n"
                  <> "activeAccounts" |- "_"
                  <> "accounts" |- indent 2 ("\n" <> (unpack $
                    Text.unlines (flip fmap (contractFromRewrite <$> _stateUpdates) $ \a ->
                      pack $
                        kAccount pass a
                          (fromMaybe
                            (error $ show a ++ " not found in accounts: " ++ show accounts)
                            $ Map.lookup a accounts
                          )
                          (filter (\u -> contractFromRewrite u == a) _stateUpdates)
                          )))
                  <> "txOrder" |- "_"
                  <> "txPending" |- "_"
                  <> "messages" |- "_"
                  )
               <> "\nrequires "
               <> defaultConditions (kVar _contract) <> "\n andBool\n"
               <> kExpr (mconcat _preconditions)
               <> "\nensures "
               <> kExpr (mconcat _postconditions)
