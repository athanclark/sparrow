{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , GADTs
  , FlexibleContexts
  , OverloadedStrings
  , ConstraintKinds
  #-}

module Web.Dependencies.Sparrow.Server where

import Web.Dependencies.Sparrow.Types
  ( Server
  , ServerArgs (..)
  , ServerReturn (..)
  , ServerContinue (..)
  , Topic (..)
  , WithSessionID (..)
  , WithTopic (..)
  , InitResponse (..)
  , WSHTTPResponse (..)
  , WSIncoming (..)
  , WSOutgoing (..)
  )
import Web.Dependencies.Sparrow.Session (SessionID (..))
import Web.Dependencies.Sparrow.Server.Types
  ( SparrowServerT
  , Env (..)
  , ask'
  , tell'
  , execSparrowServerT
  , execSparrowServerT'
  , sendTo
  , unsafeRegisterReceive
  , registerOnUnsubscribe
  , registerOnOpenThread
  , registerInvalidator
  , broadcaster
  , getCurrentRegisteredTopics
  , getCallReceive
  , killOnOpenThread
  , killAllOnOpenThreads
  , callOnUnsubscribe
  , callAllOnUnsubscribe
  , unregisterReceive
  , unregisterSession
  , addSubscriber
  , delSubscriber
  , delSubscriberFromAllTopics
  )

import Web.Routes.Nested (Match, UrlChunks, RouterT (..), ExtrudeSoundly)
import qualified Web.Routes.Nested as NR
import Data.Aeson (FromJSON, ToJSON (toJSON), Value)
import qualified Data.Aeson as Aeson
import Data.Trie.Pred.Interface.Types (Singleton (singleton), Extrude (extrude))
import Data.Monoid ((<>))
import qualified Data.UUID as UUID
import Data.Singleton.Class (Extractable (runSingleton))
import Data.Proxy (Proxy (..))
import Control.Monad (join, forever)
import Control.Monad.Trans (lift)
import Control.Monad.State (modify')
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, tryTakeTMVar, putTMVar, isEmptyTMVar, swapTMVar)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import Network.Wai.Trans (MiddlewareT, strictRequestBody, queryString, websocketsOrT)
import Network.Wai.Middleware.ContentType.Json (jsonOnly)
import Network.WebSockets (defaultConnectionOptions)
import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toServerAppT)
import Network.HTTP.Types (status400)
import System.IO.Unsafe (unsafePerformIO)




-- | Called per-connection
unpackServer :: forall m stM http initIn initOut deltaIn deltaOut
              . MonadIO m
             => Aligned.MonadBaseControl IO m stM
             => Extractable stM
             => FromJSON initIn
             => ToJSON initOut
             => FromJSON deltaIn
             => ToJSON deltaOut
             => Topic
             -> Server m initIn initOut deltaIn deltaOut
             -> SparrowServerT http m (MiddlewareT m)
unpackServer topic server = do
  env <- ask'

  -- register topic's invalidator for `deltaIn` globally
  liftIO $ atomically $
    registerInvalidator env topic (Proxy :: Proxy deltaIn)

  pure $ \app req resp -> do
    -- attempt decoding POST data
    b <- liftIO (strictRequestBody req)
    case Aeson.decode b of
      Nothing -> resp (jsonOnly (InitBadEncoding b :: InitResponse ()) status400 [])
      Just WithSessionID
        { withSessionIDContent
        , withSessionIDSessionID
        } -> case Aeson.fromJSON withSessionIDContent of -- decode as `initIn`
        Aeson.Error e -> resp (jsonOnly (InitDecodingError e :: InitResponse ()) status400 [])
        Aeson.Success (initIn :: initIn) -> do

          -- invoke Server
          mContinue <- server initIn
          case mContinue of
            Nothing -> resp (jsonOnly (InitRejected :: InitResponse ()) status400 [])
            Just ServerContinue{serverContinue,serverOnUnsubscribe} -> do

              liftIO $ atomically $ do
                registerOnUnsubscribe env withSessionIDSessionID topic serverOnUnsubscribe

                -- notify client of added subscription
                sendTo env withSessionIDSessionID (WSTopicAdded topic)

              let serverArgs :: ServerArgs m deltaOut
                  serverArgs = ServerArgs
                    { serverDeltaReject = liftIO $ do
                      unregisterReceive env withSessionIDSessionID topic
                      atomically $ do
                        delSubscriber env topic withSessionIDSessionID

                        sendTo env withSessionIDSessionID (WSTopicRejected topic)
                      killOnOpenThread env withSessionIDSessionID topic
                    , serverSendCurrent = \x -> do
                      liftIO $ do
                        let x' = WSOutgoing (WithTopic topic (toJSON x))
                        putStrLn $ "Loading toSend: " ++ show (withSessionIDSessionID,x')
                        atomically (sendTo env withSessionIDSessionID x')
                    }

              ServerReturn
                { serverInitOut
                , serverOnOpen
                , serverOnReceive
                } <- serverContinue (broadcaster env)

              liftIO $ do
                putStrLn "Registering onReceive..."
                -- register onReceive
                -- TODO security policy for consuming sessionIDs, expiring & pending
                -- check if currently "used", reject if topic is already subscribed
                --   - can have pending sessionIDs... for a while
                -- check if currently subscribed to that topic
                unsafeRegisterReceive env withSessionIDSessionID topic
                  (\v -> case Aeson.fromJSON v of
                      Aeson.Error e -> unsafePerformIO $ Nothing <$ putStrLn ("Error, deltaIn decoding error: " ++ e)
                      Aeson.Success (x :: deltaIn) -> Just (serverOnReceive serverArgs x)
                  )

                topics <- getCurrentRegisteredTopics env withSessionIDSessionID
                putStrLn $ "Topics...? " ++ show topics

                atomically $
                  addSubscriber env topic withSessionIDSessionID

              thread <- Aligned.liftBaseWith $ \runInBase ->
                async $ (\x -> runSingleton <$> runInBase x) $ serverOnOpen serverArgs

              liftIO $ atomically $ do
                -- register onOpen thread
                registerOnOpenThread env withSessionIDSessionID topic thread

              (NR.action $ NR.post $ NR.json serverInitOut) app req resp


match :: Monad m
      => Match xs' xs childHttp resultHttp
      => UrlChunks xs
      -> childHttp
      -> SparrowServerT resultHttp m ()
match ts http =
  tell' (singleton ts http)



type MatchGroup xs' xs childHttp resultHttp =
  ( ExtrudeSoundly xs' xs childHttp resultHttp
  )


matchGroup :: Monad m
           => MatchGroup xs' xs childHttp resultHttp
           => UrlChunks xs
           -> SparrowServerT childHttp m ()
           -> SparrowServerT resultHttp m ()
matchGroup ts x = do
  env <- ask'
  http <- lift (execSparrowServerT' env x)
  tell' (extrude ts http)



serveDependencies :: forall m stM sec a
                   . MonadBaseControl IO m
                  => Aligned.MonadBaseControl IO m stM
                  => Extractable stM
                  => MonadIO m
                  => MonadCatch m
                  => SparrowServerT (MiddlewareT m) m a
                  -> m (RouterT (MiddlewareT m) sec m ())
serveDependencies server = Aligned.liftBaseWith $ \runInBase -> do
  let runM :: forall b. m b -> IO b
      runM x = runSingleton <$> runInBase x

  pure $ do
    (httpTrie, env@Env{envSessionsOutgoing}) <- lift (execSparrowServerT server)

    NR.matchGroup (NR.l_ "dependencies" NR.</> NR.o_) $ do
      -- RESTful initIn -> initOut endpoints
      RouterT (modify' (<> NR.Tries httpTrie mempty mempty))

      -- websocket
      NR.matchHere $ \app req resp -> case join (lookup "sessionID" (queryString req))
                                           >>= UUID.fromASCIIBytes of
        Nothing -> resp (jsonOnly NoSessionID status400 [])
        Just sID -> do
          let sessionID = SessionID sID

          -- For listening on the outgoing TMapChan envSessionsOutgoing
          (outgoingListener :: TMVar (Async ())) <- liftIO newEmptyTMVarIO

          let wsApp :: WebSocketsApp m (WSIncoming (WithTopic Value)) (WSOutgoing (WithTopic Value))
              wsApp = WebSocketsApp
                { onOpen = \WebSocketsAppParams{send} -> do
                    liftIO $ do
                      putStrLn $ "Opened session " ++ show sessionID
                      ks <- getCurrentRegisteredTopics env sessionID
                      putStrLn $ "Fucking topics?? " ++ show ks
                      -- spawn and store TMapChan envSessionsOutgoing listener
                      listener <- async $ forever $ do
                        x <- atomically (TMapChan.lookup envSessionsOutgoing sessionID)
                        putStrLn $ "Sending... " ++ show x
                        runM (send x)
                      atomically $ putTMVar outgoingListener listener

                    initSubs <- liftIO $ getCurrentRegisteredTopics env sessionID

                    liftIO $ putStrLn $ "Uh... got initSubs: " ++ show initSubs
                
                    send (WSTopicsSubscribed initSubs)

                , onReceive = \WebSocketsAppParams{send} r -> case r of
                    WSUnsubscribe topic -> do
                      liftIO $ do
                        killOnOpenThread env sessionID topic
                        unregisterReceive env sessionID topic
                        atomically $ do
                          delSubscriber env topic sessionID

                      callOnUnsubscribe env sessionID topic

                      -- update client of removed subscription
                      send (WSTopicRemoved topic)

                    WSIncoming (WithTopic topic x) -> do
                      liftIO $ putStrLn $ "received: " ++ show (topic, x)
                      mEff <- liftIO $ getCallReceive env sessionID topic x
                      liftIO $ putStrLn "Got effect"

                      case mEff of
                        Nothing -> liftIO $ do
                          topics <- getCurrentRegisteredTopics env sessionID
                          putStrLn $ "Error, don't have a receive handler for topic: " ++ show topic ++ ", not in: " ++ show topics
                        Just eff -> eff

                , onClose = \_ _ -> do
                    liftIO $ do
                      putStrLn $ "Session " ++ show sessionID ++ " closed"
                      -- kill TMapChan envSessionsOutgoing listener
                      mListener <- atomically (tryTakeTMVar outgoingListener)
                      case mListener of
                        Nothing -> pure ()
                        Just listener -> cancel listener

                      unregisterSession env sessionID
                      atomically $ do
                        delSubscriberFromAllTopics env sessionID
                      killAllOnOpenThreads env sessionID

                    callAllOnUnsubscribe env sessionID
                }

          (websocketsOrT runM defaultConnectionOptions (toServerAppT wsApp)) app req resp
