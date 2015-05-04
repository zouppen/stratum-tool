{-# LANGUAGE DeriveDataTypeable, RecordWildCards, OverloadedStrings #-}
module Main where

import Control.Applicative
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.STM (atomically, readTChan)
import Control.Monad (when)
import Data.Aeson
import Data.ByteString.Builder
import qualified Data.HashMap.Strict as H
import qualified Data.Map as M
import qualified Data.Vector as V
import Data.Monoid
import Data.String (fromString)
import Data.Text as T (Text, pack, toLower)
import System.Console.CmdArgs.Implicit
import System.IO

import BitPay
import Common
import StratumClient
import PrettyJson

type Printer = Value -> IO ()

data Args = Args { server   :: String
                 , port     :: Int
                 , command  :: String
                 , params   :: [String]
                 , multi    :: Bool
                 , json     :: Bool
                 , follow   :: Follow
                 , currency :: String
                 , security :: Security
                 } deriving (Show, Data, Typeable)

synopsis =
  Args { server = "electrum.bittiraha.fi" &=
                  help "Electrum server address (electrum.bittiraha.fi)" &=
                  typ "HOST" &= name "s"
       , port = def &= help "Electrum port (50002 for SSL, 50001 for TCP)"
       , command = def &= argPos 0 &= typ "COMMAND"
       , params = def &= args &= typ "PARAMS"
       , multi = def &=
                 help "Instead of passing multiple parameters for a single \
                      \command, repeat command for each argument"
       , json = def &=
                help "Output as raw JSON instead of JSON breadcrumbs format"
       , follow = OneShot &=
                  help "Subscribe to given addresses and run given command \
                       \when something happens. Option '-fs' prints initial \
                       \value at start. Option '-ff' only follows future \
                       \activity. Implies --multi."
       , currency = def &= typ "CODE" &=
                    help "Convert bitcoins to given currency using BitPay. \
                         \All currency codes supported by BitPay are available."
       , security = Ssl &= name "S" &= typ "MODE" &=
                    help "Connection method to Electrum server. Possible \
                         \values: 'tcp' for unencrypted connection, \
                         \'ssl' for SSL without certificate check (default), \
                         \and 'safessl' for SSL with certificate check."
       }
  &= program "stratum-tool"
  &= summary "StratumTool v0.0.4"
  &= help "Connect to Electrum server via Stratum protocol and \
          \allows querying wallet balances etc."

main = do
  args@Args{..} <- cmdArgs synopsis
  let realPort = case (port, security) of
        (0, SafeSsl)   -> 50002
        (0, Ssl)       -> 50002
        (0, Tcp)       -> 50001
        (x, _)         -> fromIntegral x
  stratumConn <- connectStratum server realPort security
  hSetBuffering stdout LineBuffering
  bitpay <- initBitpay
  let currencyText = T.toLower $ T.pack currency
      printer ans = do
        -- First print the value as usual
        printValue json ans
        -- When currency conversion is needed, then update rates and
        -- print converted values if they contain any amounts.
        when (currency /= "" && usefulValue (currencyInjector ans Nothing)) $ do
          rates <- bitpay
          printValue json $
            currencyInjector ans $ Just $ simpleRate rates currencyText
      act = if follow /= OneShot then trackAddresses else oneTime
    in act printer stratumConn args

-- |Track changes in given addresses and run the command when changes
-- occur.
trackAddresses :: Printer -> StratumConn -> Args -> IO ()
trackAddresses printer stratumConn Args{..} = do
  chan <- stratumChan stratumConn "blockchain.address.subscribe"
  -- Subscribe and collect the hashes for future comparison
  hashes <- mapConcurrently (qv "blockchain.address.subscribe" . pure) params
  -- Print current state at first
  when (follow == ShootAndFollow) $
    oneTime printer stratumConn Args{multi=True,..}
  -- Listen for changes
  let loop m = do
        [addr,newHash] <- takeJSON <$> atomically (readTChan chan)
        if m M.! addr /= newHash
          then do newValue <- qv command [addr]
                  printer $ object [fromString addr .= newValue]
                  loop $ M.insert addr newHash m
          else loop m
    in loop $ M.fromList $ zipWith mapify params hashes
  where qv = queryStratumValue stratumConn
        mapify a h = (a, takeJSON h)

-- |Process single request. 
oneTime :: Printer -> StratumConn -> Args -> IO ()
oneTime printer stratumConn Args{..} = do
  ans <- if multi
         then objectZip params <$>
              mapConcurrently (queryStratumValue stratumConn command . pure) params
         else queryStratumValue stratumConn command params
  printer ans

-- |Prints given JSON value to stdout. When `json` is True, then just
-- print as encoded to JSON, otherwise breadcrumbs format is used.
printValue :: Bool -> Printer
printValue json ans =
  hPutBuilder stdout $ if json
                       then lazyByteString (encode ans) <> byteString "\n"
                       else breadcrumbs ans

-- |Pairs a given list of strings corresponding values to generate
-- JSON object with string as a key.
objectZip :: [String] -> [Value] -> Value
objectZip ss vs = object $ zipWith toPair ss vs
  where toPair s v = (fromString s, v)

-- |Inject currency data recursively to given Value. Vacuum all other
-- data from the JSON value.
currencyInjector :: Value -> Maybe (Text, Value) -> Value
currencyInjector v rate = recurse v
  where
    recurse (Object o) = Object $ H.filter usefulValue $ H.map conv $ H.filterWithKey isAmount o
    recurse (Array a) = Array $ V.filter usefulValue $ V.map recurse a
    recurse v = v
    -- isAmount keeps Numbers which are currencies, Objects, and Arrays
    isAmount k (Number _) = k `elem` currencyFields
    isAmount _ (Object _) = True
    isAmount _ (Array _) = True
    isAmount _ _ = False
    -- conv converts all Numbers and recurses into others
    conv (Number n) = maybe Null (inject $ Number n) rate
    conv v = recurse v

-- |List of Stratum object key names which contain bitcoin amounts.
currencyFields :: [Text]
currencyFields = ["confirmed"
                 ,"unconfirmed"
                 ,"value"
                 ]

-- |Converts given numeric value to Object containing amount in
-- satoshis and given currency.
inject :: Value -> (Text, Value) -> Value
inject (Number n) (code, Number rate) =
  object [(code, Number (n*rate*1e-8))]

-- |Filter for removing empty objects and arrays.
usefulValue :: Value -> Bool
usefulValue (Object o) = not $ H.null o
usefulValue (Array a) = not $ V.null a
usefulValue _ = True
