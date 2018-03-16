{-# LANGUAGE
    OverloadedStrings
  , NamedFieldPuns
  , FlexibleContexts
  #-}

module Main where

import Lib (InitIn (..), InitOut (..), DeltaIn (..), DeltaOut (..))

import Web.Routes.Nested (RouterT, route, o_, l_, (</>))
import Web.Dependencies.Sparrow
  ( Server, ServerArgs (..), ServerReturn (..), ServerContinue (..)
  , SparrowServerT, Topic (..), serveDependencies, unpackServer
  , match
  )
import Network.Wai.Trans (MiddlewareT, runMiddlewareT)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.ContentType.Text (textOnly)
import Network.HTTP.Types (status404)

import Data.Singleton.Class (Extractable)
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned


server :: MonadIO m
       => Server m InitIn InitOut DeltaIn DeltaOut
server InitIn = do
  liftIO $ print InitIn
  pure $ Just ServerContinue
    { serverContinue = \broadcast -> do
        liftIO $ putStrLn "Returning..."
        pure ServerReturn
          { serverInitOut = InitOut
          , serverOnOpen = \ServerArgs{serverDeltaReject,serverSendCurrent} -> do
              liftIO $ putStrLn "Sending DeltaOut onOpen..."
              serverSendCurrent DeltaOut
          , serverOnReceive = \ServerArgs{serverDeltaReject,serverSendCurrent} DeltaIn -> do
              liftIO $ putStrLn "Received DeltaIn..."
              serverDeltaReject
          }
    , serverOnUnsubscribe = do
        liftIO $ putStrLn "Unsubscribed..."
    }


routes :: Aligned.MonadBaseControl IO m stM
       => Extractable stM
       => MonadBaseControl IO m
       => MonadCatch m
       => MonadIO m
       => RouterT (MiddlewareT m) sec m ()
routes = do
  dependencies <- lift $ serveDependencies $ do
    fooServer <- unpackServer (Topic ["foo"]) server
    match (l_ "foo" </> o_) fooServer
  dependencies


main :: IO ()
main = run 3000 (route routes defApp)
  where
    defApp req resp = resp (textOnly "404" status404 [])
