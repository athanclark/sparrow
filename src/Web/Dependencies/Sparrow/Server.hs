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
  , unsafeSendTo
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
  , addSubscriber
  , delSubscriber
  , delSubscriberFromAllTopics
  )

import Web.Routes.Nested (Match, UrlChunks, RouterT (..), ExtrudeSoundly)
import qualified Web.Routes.Nested as NR
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), object, (.=), Value (Object, String))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (typeMismatch)
import Data.Trie.Pred.Interface.Types (Singleton (singleton), Extrude (extrude))
import Data.Monoid ((<>))
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.ByteString.Lazy as LBS
import qualified Data.UUID as UUID
import Data.Singleton.Class (Extractable (runSingleton))
import Data.Proxy (Proxy (..))
import Control.Applicative ((<|>))
import Control.Monad (join, forever)
import Control.Monad.Trans (lift)
import Control.Monad.State (modify')
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, tryTakeTMVar, putTMVar)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import Network.Wai.Trans (MiddlewareT, strictRequestBody, queryString, websocketsOrT)
import Network.Wai.Middleware.ContentType.Json (jsonOnly)
import Network.WebSockets (defaultConnectionOptions)
import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toServerAppT)
import Network.HTTP.Types (status400)





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
                unsafeSendTo env withSessionIDSessionID $ 
                  toJSON (WSTopicAdded topic :: WSOutgoing ())

              let serverArgs :: ServerArgs m deltaOut
                  serverArgs = ServerArgs
                    { serverDeltaReject = liftIO $ do
                      killOnOpenThread env withSessionIDSessionID topic
                      atomically $ do
                        unregisterReceive env withSessionIDSessionID topic
                        delSubscriber env topic withSessionIDSessionID

                        unsafeSendTo env withSessionIDSessionID $
                          toJSON (WSTopicRejected topic :: WSOutgoing ())
                    , serverSendCurrent =
                      liftIO . atomically . unsafeSendTo env withSessionIDSessionID . toJSON
                    }

              ServerReturn
                { serverInitOut
                , serverOnOpen
                , serverOnReceive
                } <- serverContinue (broadcaster env)

              mThread <- serverOnOpen serverArgs

              liftIO $ atomically $ do
                -- register onOpen thread
                case mThread of
                  Nothing -> pure ()
                  Just thread -> registerOnOpenThread env withSessionIDSessionID topic thread

                -- register onReceive
                -- TODO security policy for consuming sessionIDs, expiring & pending
                -- check if currently "used", reject if topic is already subscribed
                --   - can have pending sessionIDs... for a while
                -- check if currently subscribed to that topic
                unsafeRegisterReceive env withSessionIDSessionID topic
                  (\v -> case Aeson.fromJSON v of
                      Aeson.Error _ -> Nothing
                      Aeson.Success (x :: deltaIn) -> Just (serverOnReceive serverArgs x)
                  )

                addSubscriber env topic withSessionIDSessionID

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

          let wsApp :: WebSocketsApp m (WSIncoming (WithTopic Value)) (WSOutgoing Value)
              wsApp = WebSocketsApp
                { onOpen = \WebSocketsAppParams{send} -> do
                    liftIO $ do
                      -- spawn and store TMapChan envSessionsOutgoing listener
                      listener <- async $ forever $ do
                        x <- atomically $ TMapChan.lookup envSessionsOutgoing sessionID
                        runM (send (WSOutgoing x))
                      atomically (putTMVar outgoingListener listener)

                    initSubs <- liftIO $ atomically $ getCurrentRegisteredTopics env sessionID

                    send (WSTopicsSubscribed initSubs)

                , onReceive = \WebSocketsAppParams{send} r -> case r of
                    WSUnsubscribe topic -> do
                      liftIO $ do
                        killOnOpenThread env sessionID topic
                        atomically $ do
                          unregisterReceive env sessionID topic
                          delSubscriber env topic sessionID

                      callOnUnsubscribe env sessionID topic
                      -- TODO
                      --  - clean-up registered topic mappings for sessionID

                      -- update client of removed subscription
                      send (WSTopicRemoved topic)

                    WSIncoming (WithTopic topic x) -> do
                      mEff <- liftIO $ atomically $ getCallReceive env sessionID topic x

                      case mEff of
                        Nothing -> pure () -- TODO Fail
                        Just eff -> eff

                , onClose = \_ _ -> do
                    liftIO $ do
                      -- kill TMapChan envSessionsOutgoing listener
                      mListener <- atomically (tryTakeTMVar outgoingListener)
                      case mListener of
                        Nothing -> pure ()
                        Just listener -> cancel listener
                    -- TODO Clear all stored registered shit for sessionID - never will exist again
                    -- TODO cancel all threads for all topics with this sessionID

                      atomically $ delSubscriberFromAllTopics env sessionID
                      killAllOnOpenThreads env sessionID

                    callAllOnUnsubscribe env sessionID
                }

          (websocketsOrT runM defaultConnectionOptions (toServerAppT wsApp)) app req resp
