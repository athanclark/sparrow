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

import Web.Dependencies.Sparrow.Types (Server, ServerArgs (..), ServerReturn (..), ServerContinue (..), Topic (..))
import Web.Dependencies.Sparrow.Session (SessionID (..))
import Web.Dependencies.Sparrow.Server.Types (SparrowServerT, Env (..), tell', execSparrowServerT, execSparrowServerT', ask', unsafeBroadcastTopic)

import Web.Routes.Nested (Match, UrlChunks, RouterT (..), ExtrudeSoundly)
import qualified Web.Routes.Nested as NR
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), object, (.=), Value (Object, String))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (typeMismatch)
import Data.Trie.Pred.Interface.Types (Singleton (singleton), Extrude (extrude))
import Data.Monoid ((<>))
import qualified Data.Trie.Pred.Interface as PT
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.ByteString.Lazy as LBS
import qualified Data.UUID as UUID
import Data.Singleton.Class (Extractable)
import Data.Maybe (fromMaybe)
import Data.Foldable (sequenceA_)
import qualified ListT as ListT
import Control.Applicative ((<|>))
import Control.Monad (join, forever)
import Control.Monad.Trans (lift)
import Control.Monad.State (modify')
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Control.Monad.Trans.Control.Aligned as Aligned
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (TChan, TMVar, atomically, newEmptyTMVarIO, tryTakeTMVar, putTMVar)
import Control.Concurrent.STM.TMapChan.Hash (TMapChan)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import qualified STMContainers.Map as STMMap
import Network.Wai.Trans (MiddlewareT, strictRequestBody, queryString, websocketsOrT)
import Network.Wai.Middleware.ContentType.Json (jsonOnly)
import Network.WebSockets (defaultConnectionOptions)
import Network.WebSockets.Simple (WebSocketsApp (..), WebSocketsAppParams (..), toServerAppT)
import Network.HTTP.Types (status400)




data WithSessionID a = WithSessionID
  { withSessionIDSessionID :: SessionID
  , withSessionIDContent   :: a
  }

instance FromJSON a => FromJSON (WithSessionID a) where
  parseJSON (Object o) = WithSessionID <$> (o .: "sessionID") <*> (o .: "content")
  parseJSON x = typeMismatch "WithSessionID" x

data WithTopic a = WithTopic
  { withTopicTopic   :: Topic
  , withTopicContent :: a
  }

instance FromJSON a => FromJSON (WithTopic a) where
  parseJSON (Object o) = WithTopic <$> (o .: "topic") <*> (o .: "content")
  parseJSON x = typeMismatch "WithTopic" x


data InitResponse a
  = InitBadEncoding LBS.ByteString
  | InitDecodingError String -- when manually decoding the content, casted
  | InitRejected
  | InitResponse a

instance ToJSON a => ToJSON (InitResponse a) where
  toJSON x = case x of
    InitBadEncoding x -> object ["error" .= object ["badRequest" .= LT.decodeUtf8 x]]
    InitDecodingError x -> object ["error" .= object ["decoding" .= x]]
    InitRejected -> object ["error" .= String "rejected"]
    InitResponse x -> object ["content" .= x]

data WSHTTPResponse
  = NoSessionID

instance ToJSON WSHTTPResponse where
  toJSON x = case x of
    NoSessionID -> object ["error" .= String "no sessionID query parameter"]


data WSIncoming a
  = WSUnsubscribe
    { wsUnsubscribeTopic :: Topic
    }
  | WSIncoming a

instance FromJSON a => FromJSON (WSIncoming a) where
  parseJSON (Object o) = do
    let unsubscribe = WSUnsubscribe <$> o .: "unsubscribe"
        incoming = WSIncoming <$> o .: "content"
    unsubscribe <|> incoming
  parseJSON x = typeMismatch "WSIncoming" x

data WSOutgoing a
  = WSTopicsSubscribed
    { wsTopicsSubscribed :: [Topic]
    }
  | WSTopicsAdded
    { wsTopicsAdded      :: [Topic]
    }
  | WSTopicsRemoved
    { wsTopicsRemoved    :: [Topic]
    }
  | WSDecodingError String
  | WSOutgoing a

instance ToJSON a => ToJSON (WSOutgoing a) where
  toJSON x = case x of
    WSDecodingError e -> object ["error" .= object ["decoding" .= e]]
    WSTopicsSubscribed subs -> object ["subs" .= object ["init" .= subs]]
    WSTopicsAdded subs -> object ["subs" .= object ["add" .= subs]]
    WSTopicsRemoved subs -> object ["subs" .= object ["del" .= subs]]
    WSOutgoing x -> object ["content" .= x]


type InitHandler m = MiddlewareT m




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
             -> SparrowServerT http m (InitHandler m)
unpackServer topic server = do
  env@Env
    { envSessionsOutgoing
    , envRegisteredReceive
    , envRegisteredTopicInvalidators
    , envRegisteredTopicSubscribers
    , envRegisteredOnUnsubscribe
    , envRegisteredOnOpenThreads
    } <- ask'

  -- register topic's invalidator for `deltaIn` globally
  liftIO $ atomically $
    STMMap.insert (\v -> case Aeson.fromJSON v of
                    Aeson.Error e -> Just e
                    Aeson.Success (_ :: deltaIn) -> Nothing
                  ) topic envRegisteredTopicInvalidators

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
                -- register onUnsubscribe for sessionID :-> topic
                mTopics <- STMMap.lookup withSessionIDSessionID envRegisteredOnUnsubscribe
                topics <- case mTopics of
                  Nothing -> do
                    x <- STMMap.new
                    STMMap.insert x withSessionIDSessionID envRegisteredOnUnsubscribe
                    pure x
                  Just x -> pure x
                STMMap.insert serverOnUnsubscribe topic topics

                -- notify client of added subscription
                TMapChan.insert envSessionsOutgoing withSessionIDSessionID $
                  toJSON (WSTopicsAdded [topic] :: WSOutgoing ())

              let serverArgs :: ServerArgs m deltaOut
                  serverArgs = ServerArgs
                    { serverDeltaReject =
                      -- TODO
                      --  - issue a rejection message to current connection
                      --  - kill /any/ outgoing threads spawned by init
                      --  - clean-up registered topic mapping for sessionID
                      --  - invoke onUnsubscribe...?
                      pure ()
                    , serverSendCurrent =
                      liftIO . atomically . TMapChan.insert envSessionsOutgoing withSessionIDSessionID . toJSON
                    }

              ServerReturn
                { serverInitOut
                , serverOnOpen
                , serverOnReceive
                } <- serverContinue $
                -- Broadcasting facility
                \topic' -> do
                  mInvalidator <- liftIO $ atomically $ STMMap.lookup topic' envRegisteredTopicInvalidators
                  case mInvalidator of
                    Nothing -> pure Nothing
                    Just invalidator -> pure $ Just $ \v -> case invalidator v of
                      Just _ -> Nothing -- is invalid
                      Nothing -> Just (unsafeBroadcastTopic env topic' v)

              mThread <- serverOnOpen serverArgs

              liftIO $ atomically $ do
                -- register onOpen thread
                case mThread of
                  Nothing -> pure ()
                  Just thread -> do
                    mThreads <- STMMap.lookup withSessionIDSessionID envRegisteredOnOpenThreads
                    threads <- case mThreads of
                      Nothing -> do
                        x <- STMMap.new
                        STMMap.insert x withSessionIDSessionID envRegisteredOnOpenThreads
                        pure x
                      Just x -> pure x
                    STMMap.insert thread topic threads

                -- register onReceive
                -- TODO security policy for consuming sessionIDs, expiring & pending
                -- check if currently "used", reject if topic is already subscribed
                --   - can have pending sessionIDs... for a while
                -- check if currently subscribed to that topic
                mTopics <- STMMap.lookup withSessionIDSessionID envRegisteredReceive
                topics <- case mTopics of
                  Nothing -> do
                    x <- STMMap.new
                    STMMap.insert x withSessionIDSessionID envRegisteredReceive
                    pure x
                  Just x -> pure x
                STMMap.insert (\v -> case Aeson.fromJSON v of
                                  Aeson.Error _ -> Nothing
                                  Aeson.Success (x :: deltaIn) -> Just (serverOnReceive serverArgs x)
                              ) topic topics

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



dependencies :: forall m sec a
              . MonadBaseControl IO m
             => MonadIO m
             => MonadCatch m
             => (forall b. m b -> IO b)
             -> SparrowServerT (InitHandler m) m a
             -> RouterT (MiddlewareT m) sec m ()
dependencies runM server = do
  ( httpTrie
    , Env
      { envSessionsOutgoing
      , envRegisteredReceive
      , envRegisteredTopicInvalidators
      , envRegisteredTopicSubscribers
      , envRegisteredOnUnsubscribe
      , envRegisteredOnOpenThreads
      }
    ) <- lift (execSparrowServerT server)

  NR.matchGroup (NR.l_ "dependencies" NR.</> NR.o_) $ do
    -- RESTful initIn -> initOut endpoints
    RouterT (modify' (<> NR.Tries httpTrie mempty mempty))

    -- websocket
    NR.matchHere $ \app req resp -> case join (lookup "sessionID" (queryString req))
                                         >>= UUID.fromASCIIBytes of
      Nothing -> resp (jsonOnly NoSessionID status400 [])
      Just sID -> do
        let sessionID = SessionID sID

        (outgoingListener :: TMVar (Async ())) <- liftIO newEmptyTMVarIO

        let wsApp :: WebSocketsApp m (WSIncoming (WithTopic Value)) (WSOutgoing Value)
            wsApp = WebSocketsApp
              { onOpen = \WebSocketsAppParams{send,close} -> do
                  liftIO $ do
                    listener <- async $ forever $ do
                      x <- atomically $ TMapChan.lookup envSessionsOutgoing sessionID
                      runM (send (WSOutgoing x))
                    atomically (putTMVar outgoingListener listener)

                  initSubs <- liftIO $ atomically $ do
                    mTopics <- STMMap.lookup sessionID envRegisteredReceive
                    case mTopics of
                      Nothing -> pure [] -- FIXME should never happen - throw error?
                      Just ts -> fmap fst <$> ListT.toReverseList (STMMap.stream ts)

                  send (WSTopicsSubscribed initSubs)

              , onReceive = \WebSocketsAppParams{send,close} r -> case r of
                  WSUnsubscribe topic -> do
                    -- kill async thread created onOpen
                    liftIO $ do
                      mThread <- atomically $ do
                        mThreads <- STMMap.lookup sessionID envRegisteredOnOpenThreads
                        case mThreads of
                          Nothing -> pure Nothing
                          Just threads -> STMMap.lookup topic threads
                      case mThread of
                        Nothing -> pure ()
                        Just thread -> cancel thread

                    -- facilitate onUnsubscribe handler
                    eff <- liftIO $ atomically $ do
                      mTopics <- STMMap.lookup sessionID envRegisteredOnUnsubscribe
                      case mTopics of
                        Nothing -> pure (pure ())
                        Just topics -> do
                          mEff <- STMMap.lookup topic topics
                          STMMap.delete topic topics
                          pure (fromMaybe (pure ()) mEff)
                    eff
                    -- TODO
                    --  - clean-up registered topic mappings for sessionID

                    -- update client of removed subscription
                    send (WSTopicsRemoved [topic])

                  WSIncoming (WithTopic t@(Topic topic) x) -> do
                    mEff <- liftIO $ atomically $ do
                      mTopics <- STMMap.lookup sessionID envRegisteredReceive
                      case mTopics of
                        Nothing -> pure Nothing
                        Just topics -> do
                          mReceiver <- STMMap.lookup t topics
                          case mReceiver of
                            Nothing -> pure Nothing
                            Just receiver -> pure (receiver x)

                    case mEff of
                      Nothing -> pure () -- TODO Fail
                      Just eff -> eff

              , onClose = \o e -> do
                  liftIO $ do
                    mListener <- atomically (tryTakeTMVar outgoingListener)
                    case mListener of
                      Nothing -> pure ()
                      Just listener -> cancel listener
                  -- TODO Clear all stored registered shit for sessionID - never will exist again
                  -- TODO cancel all threads for all topics with this sessionID

                  -- facilitate all onUnsubscribe handlers for all topics of sessionID, after deleting them
                  effs <- liftIO $ atomically $ do
                    mTopics <- STMMap.lookup sessionID envRegisteredOnUnsubscribe
                    STMMap.delete sessionID envRegisteredOnUnsubscribe
                    case mTopics of
                      Nothing -> pure []
                      Just topics -> do
                        effs <- fmap snd <$> ListT.toReverseList (STMMap.stream topics)
                        STMMap.deleteAll topics
                        pure effs
                  sequenceA_ effs
              }

        (websocketsOrT runM defaultConnectionOptions (toServerAppT wsApp)) app req resp
