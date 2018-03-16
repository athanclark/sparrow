{-# LANGUAGE
    NamedFieldPuns
  , OverloadedStrings
  , RankNTypes
  , ScopedTypeVariables
  , FlexibleContexts
  #-}

module Web.Dependencies.Sparrow.Client where

import Web.Dependencies.Sparrow.Types
  ( Client, ClientArgs (..), ClientReturn (..)
  , Topic (..), WSIncoming (..), WSOutgoing (..), WithTopic (..), WithSessionID (..)
  )
import Web.Dependencies.Sparrow.Session (SessionID (..))
import Web.Dependencies.Sparrow.Client.Types
  ( SparrowClientT (..), Env (..), ask', RegisteredTopicSubscriptions
  , callReject, callOnReceive, registerSubscription, removeSubscription
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
import Data.UUID.V4 (nextRandom)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.HashSet (HashSet)
import qualified Data.HashSet as HS
import Control.Monad (forever)
import Control.Monad.Trans (MonadTrans (lift))
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Trans.Reader (ReaderT (runReaderT))
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM ( TMVar, TVar, TChan, atomically, newEmptyTMVarIO, newTChanIO
                              , readTChan, writeTChan, takeTMVar, putTMVar, tryTakeTMVar
                              , newTVarIO, readTVar, modifyTVar')
import Path (Path, Abs, Rel, Dir, File, toFilePath, parseRelFile, (</>), parent, dirname)
import Path.Extended (Location, fromPath, (<&>))
import System.IO.Unsafe (unsafePerformIO)
import Network.Wai.Trans (runClientAppT)
import Network.WebSockets (runClient)
import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toClientAppT, expBackoffStrategy)
import Network.HTTP.Client (parseRequest, newManager, defaultManagerSettings, method, requestBody, responseBody, responseStatus, httpLbs, RequestBody (RequestBodyLBS))
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (status200)
import Wuss (runSecureClient)


unpackClient :: forall m stM initIn initOut deltaIn deltaOut
              . MonadIO m
             => Aligned.MonadBaseControl IO m stM
             => Extractable stM
             => ToJSON initIn
             => FromJSON initOut
             => ToJSON deltaIn
             => FromJSON deltaOut
             => Topic
             -> Client m initIn initOut deltaIn deltaOut
             -> SparrowClientT m ()
unpackClient topic client = do
  env@Env{envSendInit,envSubscriptions,envSendDelta} <- ask'

  lift $ Aligned.liftBaseWith $ \runInBase -> do
    let runM :: forall b. m b -> IO b
        runM x = runSingleton <$> runInBase x

    threadVar <- newEmptyTMVarIO

    thread <- async $ runM $ client $ \ClientArgs{clientReceive,clientInitIn,clientOnReject} -> do
      mInitOut <- envSendInit topic (Aeson.toJSON clientInitIn)

      case mInitOut of
        Nothing -> do
          liftIO $ putStrLn "Error, initOut failed"
          pure Nothing -- TODO throw error
        Just v -> case Aeson.fromJSON v of
          Aeson.Error e -> do
            liftIO $ putStrLn $ "Error, initOut decoding error: " ++ e
            pure Nothing
          Aeson.Success (initOut :: initOut) -> do
            let clientUnsubscribe = do
                  envSendDelta (WSUnsubscribe topic)
                  liftIO $ do
                    thread <- atomically (takeTMVar threadVar)
                    atomically (removeSubscription env topic)
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
                      liftIO $ putStrLn $ "Error, deltaOut decoding error: " ++ e
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


allocateDependencies :: forall m stM a
                      . MonadIO m
                     => MonadBaseControl IO m
                     => Aligned.MonadBaseControl IO m stM
                     => MonadCatch m
                     => Extractable stM
                     => Bool -- ^ TLS
                     -> URIAuth -- ^ Hostname
                     -> Path Abs Dir -- ^ /dependencies
                     -> SparrowClientT m a
                     -> m ()
allocateDependencies tls auth@(URIAuth _ host port) path SparrowClientT{runSparrowClientT} = Aligned.liftBaseWith $ \runInBase -> do
  let runM :: forall b. m b -> IO b
      runM x = runSingleton <$> runInBase x

      httpURI :: Topic -> URI
      httpURI (Topic topic) =
        packLocation (Strict.Just (if tls then "https" else "http")) True auth $
          fromPath $ path </> unsafePerformIO (parseRelFile $ T.unpack $ T.intercalate "/" topic)

  sessionID <- SessionID <$> nextRandom

  let runWS :: WebSocketsApp m (WSOutgoing (WithTopic Value)) (WSIncoming (WithTopic Value)) -> IO ()
      runWS =
        let file :: Path Rel File
            file =
              let q = T.pack $ toFilePath $ dirname path
              in  unsafePerformIO $ parseRelFile $ T.unpack $ T.take (T.length q - 1) q

            loc :: Location Abs File
            loc = fromPath (parent path </> file)
                    <&> ("sessionID", Just (show sessionID))

            f | tls = runSecureClient (T.unpack $ printURIAuthHost host) (Strict.maybe 80 fromIntegral port) (show loc)
              | otherwise = runClient (T.unpack $ printURIAuthHost host) (Strict.maybe 80 fromIntegral port) (show loc)
        in  f . runClientAppT runM . toClientAppT

  ( toWSThread :: TMVar (Async ())
    ) <- newEmptyTMVarIO
  
  ( toWS :: TChan (WSIncoming (WithTopic Value))
    ) <- newTChanIO

  ( envSubscriptions :: RegisteredTopicSubscriptions m
    ) <- newTVarIO HM.empty

  ( attemptWS :: TChan ()
    ) <- newTChanIO

  httpManager <-
    if tls
    then newTlsManager
    else newManager defaultManagerSettings

  ( pendingTopicsAdded :: TVar (HashSet Topic)
    ) <- newTVarIO HS.empty

  ( pendingTopicsRemoved :: TVar (HashSet Topic)
    ) <- newTVarIO HS.empty



  let env :: Env m
      env = Env
        { envSendInit = \topic initIn -> liftIO $ do
            atomically $ modifyTVar' pendingTopicsAdded (HS.insert topic)
            req <- parseRequest $ T.unpack $ printURI $ httpURI topic
            let req' = req
                  { method = "POST"
                  , requestBody = RequestBodyLBS $ Aeson.encode $ WithSessionID
                      { withSessionIDSessionID = sessionID
                      , withSessionIDContent = initIn
                      }
                  }

            response <- httpLbs req' httpManager

            if responseStatus response == status200
            then case Aeson.eitherDecode (responseBody response) of
                    Right (initOut :: Value) -> pure (Just initOut)
                    Left e -> do
                      liftIO $ putStrLn $ "Error, initOut decoding error: " ++ e
                      pure Nothing
            else do
              liftIO $ putStrLn $ "Error, initIn returned with non-200 http status: " ++ show response
              pure Nothing
        , envSendDelta = \x -> do
            case x of
              WSUnsubscribe topic -> liftIO $ atomically $ modifyTVar' pendingTopicsRemoved (HS.insert topic)
              _ -> pure ()
            liftIO $ atomically $ writeTChan toWS x
        , envSubscriptions
        }


  --   Start clients
  (_ :: a) <- runM (runReaderT runSparrowClientT env)


  --   WebSocket

  -- start running first attempt
  atomically $ writeTChan attemptWS ()
  -- backoff strategy
  backoff <- expBackoffStrategy $ atomically $ writeTChan attemptWS ()
  -- main thread
  forever $ do
    atomically (readTChan attemptWS)

    runWS WebSocketsApp
      { onOpen = \WebSocketsAppParams{send} -> do
          liftIO $ do
            putStrLn "Opened websocket..."
            thread <- async $ forever $ do
              outgoing <- atomically (readTChan toWS)
              runM (send outgoing)
            atomically (putTMVar toWSThread thread)

      , onReceive = \_ r -> liftIO (putStrLn $ "Receiving..." ++ show r) >> case r of
          WSTopicsSubscribed topics -> pure () -- TODO verify that it's the exact state, adjust via a `join` if necessary of unsubscribe and onReject
          WSTopicAdded topic -> do
            liftIO $ do
              putStrLn $ "Added topic: " ++ show topic
              exists <- atomically $ HS.member topic <$> readTVar pendingTopicsAdded
              if exists
                then atomically $ modifyTVar' pendingTopicsAdded (HS.delete topic)
                else putStrLn $ "Error, received added topic " ++ show topic ++ " unexpectedly"
          WSTopicRemoved topic -> do
            liftIO $ do
              exists <- atomically $ HS.member topic <$> readTVar pendingTopicsRemoved
              if exists
                then atomically $ modifyTVar' pendingTopicsRemoved (HS.delete topic)
                else putStrLn $ "Error, received removed topic " ++ show topic ++ " unexpectedly"
          WSTopicRejected topic -> callReject env topic
          WSDecodingError err -> liftIO $ putStrLn $ "Error, network decoding error: " ++ err
          WSOutgoing (WithTopic topic v) -> callOnReceive env topic v
      , onClose = \_ e ->
          liftIO $ do
            thread <- atomically (takeTMVar toWSThread)
            cancel thread
            backoff e
      }
