{-# LANGUAGE
    QuasiQuotes
  , NamedFieldPuns
  , OverloadedStrings
  #-}

module Main where

import Lib (InitIn (..), InitOut (..), DeltaIn (..), DeltaOut (..))

import Web.Dependencies.Sparrow
  ( Client, ClientArgs (..), ClientReturn (..)
  , SparrowClientT, Topic (..), allocateDependencies, unpackClient
  )

import Data.URI.Auth (URIAuth (..))
import Data.URI.Auth.Host (URIAuthHost (Localhost))
import qualified Data.Strict.Maybe as Strict
import Control.Monad.IO.Class (MonadIO (..))
import Control.Concurrent (threadDelay)
import Path (absdir)


client :: MonadIO m => Client m InitIn InitOut DeltaIn DeltaOut
client call = do
  liftIO $ putStrLn "Calling..."
  mReturn <- call ClientArgs
    { clientInitIn = InitIn
    , clientOnReject = do
        liftIO $ putStrLn "Rejected..."
    , clientReceive = \ClientReturn{clientInitOut,clientUnsubscribe,clientSendCurrent} DeltaOut -> do
        liftIO $ putStrLn "Received DeltaOut..."
    }

  case mReturn of
    Nothing -> liftIO $ putStrLn "Failed..."
    Just ClientReturn{clientInitOut,clientUnsubscribe,clientSendCurrent} -> do
      liftIO $ putStrLn "Success InitOut..."
      clientSendCurrent DeltaIn



main :: IO ()
main = do
  allocateDependencies False (URIAuth Strict.Nothing Localhost (Strict.Just 3000)) $ do
    liftIO (threadDelay (10^6))
    unpackClient (Topic ["foo"]) client
