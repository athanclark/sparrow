{-# LANGUAGE
    NamedFieldPuns
  , OverloadedStrings
  , RankNTypes
  , ScopedTypeVariables
  , FlexibleContexts
  , QuasiQuotes
  #-}

module Web.Dependencies.Sparrow.Client where

import Web.Dependencies.Sparrow.Types
  ( Client, ClientArgs (..), ClientReturn (..), newSessionID
  , Topic, topicToRelFile, WSIncoming (..), WSOutgoing (..), WithTopic (..), WithSessionID (..)
  )
import Web.Dependencies.Sparrow.Client.Types
  ( SparrowClientT (..), Env (..), ask', RegisteredTopicSubscriptions
  , callReject, callOnReceive, registerSubscription, removeSubscription
  , SparrowClientException (..)
  )

import Data.URI (URI, printURI)
import Data.URI.Auth (URIAuth (..))
import Data.URI.Auth.Host (printURIAuthHost)
import Data.Url (packLocation)
import qualified Data.Text as T
import qualified Data.Strict.Maybe as Strict
import Data.Aeson (FromJSON, ToJSON, Value)
import qualified Data.Aeson as Aeson
import Data.Singleton.Class (Extractable (runSingleton))
import Data.HashSet (HashSet)
import qualified Data.HashSet as HS
import Control.Monad (forever)
import Control.Monad.Trans (MonadTrans (lift))
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Catch (MonadCatch, MonadThrow (..))
import Control.Monad.Trans.Reader (ReaderT (runReaderT))
import Control.Concurrent.Async (Async, async, cancel, wait)
import Control.Concurrent.STM ( TMVar, TVar, TChan, atomically, newEmptyTMVarIO, newTChanIO
                              , readTChan, writeTChan, takeTMVar, putTMVar, tryTakeTMVar
                              , newTVarIO, readTVar, modifyTVar')
import Control.Concurrent.STM.TMapMVar (newTMapMVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception (evaluate)
import Path (toFilePath, parseRelFile, (</>), parent, dirname, absdir)
import Path.Extended (Location, fromAbsFile, (<&>), printLocation)
import Network.WebSockets (runClient)
import Network.WebSockets.Trans (runClientAppT)
import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toClientAppT, expBackoffStrategy)
import Network.WebSockets.Simple.PingPong (pingPong)
import Network.HTTP.Client (parseRequest, newManager, defaultManagerSettings, method, requestBody, responseBody, responseStatus, httpLbs, RequestBody (RequestBodyLBS))
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (status200)
import Wuss (runSecureClient)


-- | Adds a client for a particular topic to the builder
unpackClient :: forall m stM initIn initOut deltaIn deltaOut
              . MonadIO m
             => MonadThrow m
             => Aligned.MonadBaseControl IO m stM
             => Extractable stM
             => ToJSON initIn
             => FromJSON initOut
             => ToJSON deltaIn
             => FromJSON deltaOut
             => Topic -- ^ Dependency name
             -> Client m initIn initOut deltaIn deltaOut -- ^ Handler
             -> SparrowClientT m ()
unpackClient topic client = do
  env@Env{envSendInit,envSendDelta} <- ask'

  lift $ Aligned.liftBaseWith $ \runInBase -> do
    let runM :: forall b. m b -> IO b
        runM x = runSingleton <$> runInBase x

    threadVar <- newEmptyTMVarIO

    -- spawn a new thread for the client
    thread <- async $ runM $ client $ \ClientArgs{clientReceive,clientInitIn,clientOnReject} -> do
      -- invoke init
      mInitOut <- envSendInit topic (Aeson.toJSON clientInitIn)

      case mInitOut of
        Nothing -> do
          _ <- throwM InitOutFailed
          pure Nothing
        Just v -> case Aeson.fromJSON v of
          Aeson.Error e -> do
            _ <- throwM (InitOutDecodingError e)
            pure Nothing
          Aeson.Success (initOut :: initOut) -> do
            let clientUnsubscribe = do
                  envSendDelta (WSUnsubscribe topic)
                  liftIO $ do
                    thread <- atomically $ do
                      removeSubscription env topic
                      takeTMVar threadVar
                    cancel thread
                clientSendCurrent =
                  envSendDelta . WSIncoming . WithTopic topic . Aeson.toJSON

                clientReturn = ClientReturn
                  { clientSendCurrent
                  , clientUnsubscribe
                  , clientInitOut = initOut
                  }

            liftIO $ atomically $
              let go :: Value -> m () -- deltaOut handler
                  go v' = case Aeson.fromJSON v' of
                    Aeson.Error e ->
                      throwM (DeltaOutDecodingError e)
                    Aeson.Success (deltaOut :: deltaOut) ->
                      clientReceive clientReturn deltaOut
              in  registerSubscription env topic
                    go
                    ( do clientOnReject
                         liftIO $ do
                           mThread <- atomically $ tryTakeTMVar threadVar
                           case mThread of
                             Nothing -> pure ()
                             Just thread -> cancel thread
                    )

            pure (Just clientReturn)

    atomically (putTMVar threadVar thread)


-- | Runs the client builder
allocateDependencies :: forall m stM a
                      . MonadIO m
                     => MonadBaseControl IO m
                     => Aligned.MonadBaseControl IO m stM
                     => MonadCatch m
                     => Extractable stM
                     => Bool -- ^ TLS
                     -> URIAuth -- ^ Hostname
                     -> SparrowClientT m a -- ^ All dependencies
                     -> m ()
allocateDependencies tls auth@(URIAuth _ host port) SparrowClientT{runSparrowClientT} = Aligned.liftBaseWith $ \runInBase -> do
  let path = [absdir|/dependencies/|]

      runM :: forall b. m b -> IO b
      runM x = runSingleton <$> runInBase x

      httpURI :: Topic -> URI
      httpURI topic =
        packLocation (Strict.Just (if tls then "https" else "http")) True auth $
          fromAbsFile $ path </> topicToRelFile topic

  sessionID <- newSessionID
  let q = T.pack $ toFilePath $ dirname path
  file <- parseRelFile $ T.unpack $ T.take (T.length q - 1) q

  let runWS :: WebSocketsApp m (WSOutgoing (WithTopic Value)) (WSIncoming (WithTopic Value)) -> IO ()
      runWS x = do
        let loc :: Location
            loc = fromAbsFile (parent path </> file)
                    <&> ("sessionID", Just (show sessionID))

            f | tls = runSecureClient (T.unpack $ printURIAuthHost host) (Strict.maybe 80 fromIntegral port) $ T.unpack $ printLocation loc
              | otherwise = runClient (T.unpack $ printURIAuthHost host) (Strict.maybe 80 fromIntegral port) $ T.unpack $ printLocation loc

        x' <- runM (pingPong ((10^(6 :: Int)) * 10) x) -- every 10 seconds
        x'' <- runM (runClientAppT (toClientAppT x'))
        f x''

  ( toWSThread :: TMVar (Async ())
    ) <- newEmptyTMVarIO
  ( toWS :: TChan (WSIncoming (WithTopic Value))
    ) <- newTChanIO
  ( envSubscriptions :: RegisteredTopicSubscriptions m
    ) <- atomically newTMapMVar
  ( pendingTopicsAdded :: TVar (HashSet Topic)
    ) <- newTVarIO HS.empty
  ( pendingTopicsRemoved :: TVar (HashSet Topic)
    ) <- newTVarIO HS.empty

  httpManager <-
    if tls
    then newTlsManager
    else newManager defaultManagerSettings


  let env :: Env m
      env = Env
        { envSendInit = \topic initIn -> liftIO $ do
            atomically $ modifyTVar' pendingTopicsAdded (HS.insert topic)
            req <- parseRequest $ T.unpack $ printURI $ httpURI topic
            let req' = req
                  { method = "POST"
                  , requestBody = RequestBodyLBS $ Aeson.encode WithSessionID
                      { withSessionIDSessionID = sessionID
                      , withSessionIDContent = initIn
                      }
                  }

            response <- httpLbs req' httpManager

            if responseStatus response == status200
            then case Aeson.eitherDecode (responseBody response) of
                    Right (initOut :: Value) -> pure (Just initOut)
                    Left e -> do
                      _ <- throwM (InitOutDecodingError e)
                      pure Nothing
            else do
              _ <- throwM InitOutHTTPError
              pure Nothing
        , envSendDelta = \x -> do
            case x of
              WSUnsubscribe topic -> liftIO $ atomically $ modifyTVar' pendingTopicsRemoved (HS.insert topic)
              _ -> pure ()
            liftIO $ atomically $ writeTChan toWS x
        , envSubscriptions
        }


  --   WebSocket
  ( attemptWS :: TChan ()
    ) <- newTChanIO

  -- start running first attempt
  atomically $ writeTChan attemptWS ()
  -- backoff strategy
  backoff <- expBackoffStrategy $ atomically $ writeTChan attemptWS ()
  -- main thread
  ws <- async $ forever $ do
    atomically (readTChan attemptWS)

    runWS WebSocketsApp
      { onOpen = \WebSocketsAppParams{send} -> do
          liftIO $ do
            thread <- async $ forever $ do
              outgoing <- atomically (readTChan toWS)
              runM (send outgoing)
            atomically (putTMVar toWSThread thread)

      , onReceive = \_ r -> do
        liftIO $ evaluate (rnf r)
        case r of
          WSTopicsSubscribed topics -> pure () -- TODO verify that it's the exact state, adjust via a `join` if necessary of unsubscribe and onReject
          WSTopicAdded topic -> do
            liftIO $ do
              exists <- atomically $ HS.member topic <$> readTVar pendingTopicsAdded
              if exists
                then atomically $ modifyTVar' pendingTopicsAdded (HS.delete topic)
                else throwM (UnexpectedAddedTopic topic)
          WSTopicRemoved topic -> do
            liftIO $ do
              exists <- atomically $ HS.member topic <$> readTVar pendingTopicsRemoved
              if exists
                then atomically $ modifyTVar' pendingTopicsRemoved (HS.delete topic)
                else throwM (UnexpectedRemovedTopic topic)
          WSTopicRejected topic -> callReject env topic
          WSOutgoing (WithTopic topic v) -> callOnReceive env topic v
      , onClose = \_ e ->
          liftIO $ do
            thread <- atomically (takeTMVar toWSThread)
            cancel thread
            backoff e
      }

  --   Start clients
  z <- runM (runReaderT runSparrowClientT env)
  _ <- evaluate z

  wait ws
