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

import Data.Singleton.Class (Extractable (..))
import Control.Monad (forever)
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, link)


server :: MonadIO m
       => Aligned.MonadBaseControl IO m stM
       => Extractable stM
       => Server m InitIn InitOut DeltaIn DeltaOut
server InitIn = do
  liftIO $ putStrLn "  ## Init"
  pure $ Just ServerContinue
    { serverContinue = \broadcast -> do
        liftIO $ putStrLn "  ## Returning"
        pure ServerReturn
          { serverInitOut = InitOut
          , serverOnOpen = \ServerArgs{serverDeltaReject,serverSendCurrent} -> do
              Aligned.liftBaseWith $ \runInBase -> do
                let runM x = runSingleton <$> runInBase x
                thread <- async $ forever $ do
                  putStrLn "  ## Sending DeltaOut onOpen"
                  runM (serverSendCurrent DeltaOut)
                  threadDelay $ (10^6) * 2
                pure (Just thread)
          , serverOnReceive = \ServerArgs{serverDeltaReject,serverSendCurrent} DeltaIn -> do
              liftIO $ putStrLn "  ## Received DeltaIn and Rejecting"
              -- serverDeltaReject
          }
    , serverOnUnsubscribe = do
        liftIO $ putStrLn "  ## Unsubscribed"
    }


routes :: Aligned.MonadBaseControl IO m stM
       => Extractable stM
       => MonadBaseControl IO m
       => MonadCatch m
       => MonadIO m
       => RouterT (MiddlewareT m) sec m ()
routes = pure ()


main :: IO ()
main = do
  dependencies <- serveDependencies $ do
    fooServer <- unpackServer (Topic ["foo"]) server
    match (l_ "foo" </> o_) fooServer
  run 3000 (route dependencies defApp)
  where
    defApp req resp = resp (textOnly "404" status404 [])
