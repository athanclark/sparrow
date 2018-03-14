{-# LANGUAGE
    NamedFieldPuns
  , OverloadedStrings
  #-}

module Web.Dependencies.Sparrow.Client where

import Web.Dependencies.Sparrow.Types (Client, ClientArgs (..), Topic (..))
import Web.Dependencies.Sparrow.Client.Types (SparrowClientT (..))

import Data.URI.Auth (URIAuth (..))
import Data.URI.Auth.Host (printURIAuthHost)
import Data.Url (packLocation)
import qualified Data.Text as T
import qualified Data.Strict.Maybe as Strict
import Control.Monad.Trans (MonadTrans (lift))
import Path (Path, Abs, Dir, toFilePath, parseRelFile, (</>))
import Path.Extended (fromPath)
import System.IO.Unsafe (unsafePerformIO)
import Network.WebSockets (runClient)
import Wuss (runSecureClient)


unpackClient :: Monad m
             => Topic
             -> Client m initIn initOut deltaIn deltaOut
             -> SparrowClientT m ()
unpackClient topic client = do
  lift $ client $ \ClientArgs{clientReceive,clientInitIn,clientOnReject} ->
    pure Nothing


allocateDependencies :: Monad m
                     => Bool -- ^ TLS
                     -> URIAuth
                     -> Path Abs Dir
                     -> SparrowClientT m a
                     -> m ()
allocateDependencies tls auth@(URIAuth _ host port) path (SparrowClientT r) = do
  let httpURI (Topic topic) =
        packLocation (Strict.Just (if tls then "https" else "http")) True auth $
          fromPath $ path </> unsafePerformIO (parseRelFile $ T.unpack $ T.intercalate "/" topic)

      runWS
        | tls = runSecureClient (T.unpack $ printURIAuthHost host) (Strict.maybe 80 fromIntegral port) (toFilePath path) 
        | otherwise = runClient (T.unpack $ printURIAuthHost host) (Strict.maybe 80 fromIntegral port) (toFilePath path) 

  undefined

  -- TODO... threads? Thunk of pending subs?
  -- env <- Env <$> 
  -- runReaderT r env
