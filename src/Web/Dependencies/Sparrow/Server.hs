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
  , Topic
  , WithSessionID (..)
  , WithTopic (..)
  , InitResponse (..)
  , WSHTTPResponse (..)
  , WSIncoming (..)
  , WSOutgoing (..)
  , sessionIDFromQueryString
  )
import Web.Dependencies.Sparrow.Server.Types
  ( SparrowServerT
  , ask'
  , tell'
  , execSparrowServerT
  , execSparrowServerT'
  , sendTo
  , getSent
  , unsafeRegisterReceive
  , registerOnUnsubscribe
  , registerOnOpenThreads
  , registerInvalidator
  , broadcaster
  , getCurrentRegisteredTopics
  , getCallReceive
  , killOnOpenThreads
  , killAllOnOpenThreads
  , callOnUnsubscribe
  , callAllOnUnsubscribe
  , unregisterReceive
  , unregisterSession
  , addSubscriber
  , delSubscriber
  , delSubscriberFromAllTopics
  , SparrowServerException (..)
  )

import Web.Routes.Nested (Match, UrlChunks, RouterT (..), ExtrudeSoundly)
import qualified Web.Routes.Nested as NR
import Data.Aeson (FromJSON, ToJSON (toJSON), Value)
import qualified Data.Aeson as Aeson
import Data.Trie.Pred.Interface.Types (Singleton (singleton), Extrude (extrude))
import Data.Monoid ((<>))
import Data.Singleton.Class (Extractable (runSingleton))
import Data.Proxy (Proxy (..))
import Data.Foldable (Foldable)
import Control.Applicative (Alternative)
import Control.Monad (forever)
import Control.Monad.Trans (lift)
import Control.Monad.State (modify')
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (MonadCatch, MonadThrow (..))
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, tryTakeTMVar, putTMVar)
import Control.Exception (evaluate)
import Control.DeepSeq (NFData (rnf))
import Network.Wai (strictRequestBody)
import Network.Wai.Trans (MiddlewareT)
import Network.Wai.Middleware.ContentType.Json (jsonOnly)
import Network.WebSockets (defaultConnectionOptions)
import Network.WebSockets.Trans (websocketsOrT)
import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toServerAppT)
import Network.WebSockets.Simple.PingPong (pingPong)
import Network.HTTP.Types (status400)




-- | Called per-connection
unpackServer :: forall m f stM http initIn initOut deltaIn deltaOut
              . MonadIO m
             => Aligned.MonadBaseControl IO m stM
             => Extractable stM
             => FromJSON initIn
             => ToJSON initOut
             => FromJSON deltaIn
             => ToJSON deltaOut
             => Foldable f
             => Topic -- ^ Name of Dependency
             -> Server m f initIn initOut deltaIn deltaOut -- ^ Handler for all clients
             -> SparrowServerT http f m (MiddlewareT m)
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

          -- ##  invoke Server
          mContinue <- server initIn
          case mContinue of
            -- FIXME There's got to be some kind of error type
            Nothing -> resp (jsonOnly (InitRejected :: InitResponse ()) status400 [])
            Just ServerContinue{serverContinue,serverOnUnsubscribe} -> do

              liftIO $ atomically $ do
                registerOnUnsubscribe env withSessionIDSessionID topic serverOnUnsubscribe

                -- notify client of added subscription
                sendTo env withSessionIDSessionID (WSTopicAdded topic)

              let serverArgs :: ServerArgs m deltaOut
                  serverArgs = ServerArgs
                    { serverDeltaReject = liftIO $ do
                      atomically $ do
                        unregisterReceive env withSessionIDSessionID topic
                        delSubscriber env topic withSessionIDSessionID

                        sendTo env withSessionIDSessionID (WSTopicRejected topic)
                      killOnOpenThreads env withSessionIDSessionID topic
                    , serverSendCurrent =
                      liftIO . atomically . sendTo env withSessionIDSessionID . WSOutgoing . WithTopic topic . toJSON
                    }

              ServerReturn
                { serverInitOut
                , serverOnOpen
                , serverOnReceive
                } <- serverContinue (broadcaster env)

                -- register onReceive
                -- TODO security policy for consuming sessionIDs, expiring & pending
                -- check if currently "used", reject if topic is already subscribed
                --   - can have pending sessionIDs... for a while
                -- check if currently subscribed to that topic
              liftIO $ atomically $ do
                unsafeRegisterReceive env withSessionIDSessionID topic
                  (\v -> case Aeson.fromJSON v of
                      Aeson.Error _ -> Nothing
                      Aeson.Success (x :: deltaIn) -> Just (serverOnReceive serverArgs x)
                  )
                addSubscriber env topic withSessionIDSessionID

              threads <- serverOnOpen serverArgs

              liftIO $ atomically $
                -- register onOpen thread
                registerOnOpenThreads env withSessionIDSessionID topic threads

              (NR.action $ NR.post $ \_ -> NR.json serverInitOut) app req resp


-- | Match an individual dependency
match :: Monad m
      => Match xs' xs childHttp resultHttp
      => UrlChunks xs -- ^ Should match the dependency name
      -> childHttp -- ^ 'Network.Wai.Trans.MiddlewareT', or a function to one
      -> SparrowServerT resultHttp f m ()
match ts http =
  tell' (singleton ts http)



type MatchGroup xs' xs childHttp resultHttp =
  ( ExtrudeSoundly xs' xs childHttp resultHttp
  )


-- | Group together a set of dependencies
matchGroup :: Monad m
           => MatchGroup xs' xs childHttp resultHttp
           => UrlChunks xs -- ^ Common 'Topic' prefix
           -> SparrowServerT childHttp f m () -- ^ Set of handlers
           -> SparrowServerT resultHttp f m ()
matchGroup ts x = do
  env <- ask'
  http <- lift (execSparrowServerT' env x)
  tell' (extrude ts http)


-- | Host dependencies and websocket
serveDependencies :: forall f m stM sec a
                   . MonadBaseControl IO m
                  => Aligned.MonadBaseControl IO m stM
                  => Extractable stM
                  => MonadIO m
                  => MonadCatch m
                  => Foldable f
                  => Alternative f
                  => SparrowServerT (MiddlewareT m) f m a -- ^ Dependencies
                  -> m (RouterT (MiddlewareT m) sec m ())
serveDependencies server = Aligned.liftBaseWith $ \runInBase -> do
  let runM :: forall b. m b -> IO b
      runM x = runSingleton <$> runInBase x

  (httpTrie,env) <- runM (execSparrowServerT server)

  evaluate (rnf httpTrie)

  pure $ NR.matchGroup (NR.l_ "dependencies" NR.</> NR.o_) $ do
    -- websocket
    NR.matchHere $ \app req resp -> case sessionIDFromQueryString req of
      Nothing -> resp (jsonOnly NoSessionID status400 [])
      Just sessionID -> do
        -- For listening on the outgoing TMapChan envSessionsOutgoing
        (outgoingListener :: TMVar (Async ())) <- liftIO newEmptyTMVarIO

        let wsApp :: WebSocketsApp m (WSIncoming (WithTopic Value)) (WSOutgoing (WithTopic Value))
            wsApp = WebSocketsApp
              { onOpen = \WebSocketsAppParams{send} -> do
                  liftIO $ do
                    -- spawn and store TMapChan envSessionsOutgoing listener
                    listener <- async $ forever $ do
                      x <- atomically (getSent env sessionID)
                      runM (send x)
                    atomically (putTMVar outgoingListener listener)

                  initSubs <- liftIO $ atomically $ getCurrentRegisteredTopics env sessionID

                  send (WSTopicsSubscribed initSubs)

              , onReceive = \WebSocketsAppParams{send} r -> do
                  case r of
                    WSUnsubscribe topic -> do
                      liftIO $ atomically $ do
                        unregisterReceive env sessionID topic
                        delSubscriber env topic sessionID

                      callOnUnsubscribe env sessionID topic

                      -- update client of removed subscription
                      send (WSTopicRemoved topic)

                      liftIO (killOnOpenThreads env sessionID topic)

                    WSIncoming (WithTopic topic x) -> do
                      mEff <- liftIO $ atomically $ getCallReceive env sessionID topic x
                      case mEff of
                        Nothing -> throwM (NoHandlerForTopic topic)
                        Just eff -> eff

              , onClose = \_ _ -> do
                  liftIO $ do
                    -- kill TMapChan envSessionsOutgoing listener
                    mListener <- atomically (tryTakeTMVar outgoingListener)
                    case mListener of
                      Nothing -> pure ()
                      Just listener -> cancel listener

                    atomically $ do
                      unregisterSession env sessionID
                      delSubscriberFromAllTopics env sessionID

                  callAllOnUnsubscribe env sessionID
                  liftIO (killAllOnOpenThreads env sessionID)
              }

        wsApp' <- pingPong ((10^(6 :: Int)) * 10) wsApp -- every 10 seconds

        (websocketsOrT defaultConnectionOptions (toServerAppT wsApp')) app req resp

    -- RESTful initIn -> initOut endpoints
    RouterT (modify' (<> NR.Tries httpTrie mempty mempty))

