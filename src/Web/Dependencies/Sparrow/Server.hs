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
import Web.Dependencies.Sparrow.Server.Types
  ( SparrowServerT
  , Env (..)
  , ask'
  , tell'
  , execSparrowServerT
  , execSparrowServerT'
  , unsafeBroadcastTopic
  , unsafeSendTo
  , unsafeRegisterReceive
  , registerOnUnsubscribe
  , registerOnOpenThread
  , broadcaster
  , getCurrentRegisteredTopics
  , getCallReceive
  , killOnOpenThread
  , callOnUnsubscribe
  )

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
                registerOnUnsubscribe env withSessionIDSessionID topic serverOnUnsubscribe

                -- notify client of added subscription
                unsafeSendTo env withSessionIDSessionID $ 
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
    , env@Env
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

        -- For listening on the outgoing TMapChan envSessionsOutgoing
        (outgoingListener :: TMVar (Async ())) <- liftIO newEmptyTMVarIO

        let wsApp :: WebSocketsApp m (WSIncoming (WithTopic Value)) (WSOutgoing Value)
            wsApp = WebSocketsApp
              { onOpen = \WebSocketsAppParams{send,close} -> do
                  liftIO $ do
                    listener <- async $ forever $ do
                      x <- atomically $ TMapChan.lookup envSessionsOutgoing sessionID
                      runM (send (WSOutgoing x))
                    atomically (putTMVar outgoingListener listener)

                  initSubs <- liftIO $ atomically $ getCurrentRegisteredTopics env sessionID

                  send (WSTopicsSubscribed initSubs)

              , onReceive = \WebSocketsAppParams{send,close} r -> case r of
                  WSUnsubscribe topic -> do
                    liftIO $ killOnOpenThread env sessionID topic

                    callOnUnsubscribe env sessionID topic
                    -- TODO
                    --  - clean-up registered topic mappings for sessionID

                    -- update client of removed subscription
                    send (WSTopicsRemoved [topic])

                  WSIncoming (WithTopic t@(Topic topic) x) -> do
                    mEff <- liftIO $ atomically $ getCallReceive env sessionID t x

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
