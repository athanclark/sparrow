{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , GADTs
  , FlexibleContexts
  , OverloadedStrings
  #-}

module Web.Dependencies.Sparrow.Server where

import Web.Dependencies.Sparrow.Types (Server, ServerArgs (..), ServerReturn (..), ServerContinue (..), Topic (..))
import Web.Dependencies.Sparrow.Session (SessionID (..))
import Web.Dependencies.Sparrow.Server.Types (SparrowServerT, tell', execSparrowServerT, execSparrowServerT', ask', unsafeBroadcastTopic)

import Web.Routes.Nested (Match, UrlChunks, RouterT (..))
import qualified Web.Routes.Nested as NR
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), object, (.=), Value (Object, String))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (typeMismatch)
import Data.Trie.Pred.Interface.Types (Singleton (singleton))
import Data.Monoid ((<>))
import qualified Data.Trie.Pred.Interface as PT
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.ByteString.Lazy as LBS
import qualified Data.UUID as UUID
import Data.Singleton.Class (Extractable)
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
  env@
    ( sessions
    , registeredReceives
    , registeredTopicInvalidators
    , registeredTopicSubscribers
    ) <- ask'

  -- register topic's invalidator for `deltaIn` globally
  liftIO $ atomically $
    STMMap.insert (\v -> case Aeson.fromJSON v of
                    Aeson.Error e -> Just e
                    Aeson.Success (_ :: deltaIn) -> Nothing
                  ) topic registeredTopicInvalidators

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
            Just ServerContinue{serverContinue,serverOnUnsubscribe} -> do -- TODO perform on unsubscribe
              let sendToSessionID :: SessionID -> Value -> m ()
                  sendToSessionID sessionID x = liftIO $ atomically $ TMapChan.insert sessions sessionID x

                  serverArgs :: ServerArgs m deltaOut
                  serverArgs = ServerArgs
                    { serverDeltaReject = pure () -- TODO issue a rejection
                    , serverSendCurrent = sendToSessionID withSessionIDSessionID . toJSON
                    }

              ServerReturn{serverInitOut,serverOnOpen,serverOnReceive} <- serverContinue $ \topic' -> do
                mFunc <- liftIO $ atomically $ STMMap.lookup topic' registeredTopicInvalidators
                case mFunc of
                  Nothing -> pure Nothing
                  Just invalidator -> pure $ Just $ \v -> case invalidator v of
                    Just _ -> Nothing
                    Nothing -> Just (unsafeBroadcastTopic env topic' v)

              serverOnOpen serverArgs

              -- TODO verify that topic exists at the HTTP level
              liftIO $ atomically $ do
                mTopics <- STMMap.lookup withSessionIDSessionID registeredReceives
                topics <- case mTopics of
                  Nothing -> do
                    x <- STMMap.new
                    STMMap.insert x withSessionIDSessionID registeredReceives
                    pure x -- TODO delete map onClose
                  Just x -> pure x
                STMMap.insert (\v -> case Aeson.fromJSON v of
                                  Aeson.Error _ -> Nothing
                                  Aeson.Success (x :: deltaIn) -> Just (serverOnReceive serverArgs x)
                              ) topic topics

              (NR.action $ NR.post $ NR.json serverInitOut) app req resp
            -- check if currently "used", reject if currently connected or is topic is already subscribed
            --   - can have multiple pending... for a while
            -- sessionID :-> Either (Queue Value) (Value -> m ()) -- active & pending connections
            -- topic     :-> {sessionID}     -- active subscriptions
            -- sessionID :-> {topic}
            -- check if currently subscribed to that topic


match :: Monad m
      => Match xs' xs childHttp resultHttp
      -- => Match xs' xs childWebSocket resultWebSocket
      => UrlChunks xs
      -> childHttp
      -> SparrowServerT resultHttp m ()
match ts http =
  tell' (singleton ts http)


dependencies :: forall m sec a
              . MonadBaseControl IO m
             => MonadIO m
             => MonadCatch m
             => (forall b. m b -> IO b)
             -> SparrowServerT (InitHandler m) m a
             -> RouterT (MiddlewareT m) sec m ()
dependencies runM server = do
  ( httpTrie
    , ( sessions
      , registeredReceives
      , registeredTopicInvalidators
      , registeredTopicSubscribers
      )
    ) <- lift (execSparrowServerT server)

  NR.matchGroup (NR.l_ "dependencies" NR.</> NR.o_) $ do
    -- inits
    RouterT (modify' (<> NR.Tries httpTrie mempty mempty))

    -- websocket
    NR.matchHere $ \app req resp -> case join (lookup "sessionID" (queryString req)) >>= UUID.fromASCIIBytes of
      Nothing -> resp (jsonOnly NoSessionID status400 [])
      Just sID -> do
        let sessionID = SessionID sID

        (outgoingListener :: TMVar (Async ())) <- liftIO newEmptyTMVarIO

        let wsApp :: WebSocketsApp m (WSIncoming (WithTopic Value)) (WSOutgoing Value)
            wsApp = WebSocketsApp
              { onOpen = \WebSocketsAppParams{send,close} -> do
                  liftIO $ do
                    listener <- async $ forever $ do
                      x <- atomically $ TMapChan.lookup sessions sessionID
                      runM (send (WSOutgoing x))
                    atomically (putTMVar outgoingListener listener)
                  -- attach self to sessions mapping, facilitate subscription token set and actual subscription async updates
              , onReceive = \WebSocketsAppParams{send,close} r -> case r of
                  WSIncoming (WithTopic t@(Topic topic) x) -> do
                    mEff <- liftIO $ atomically $ do
                      mTopics <- STMMap.lookup sessionID registeredReceives
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
              }

        (websocketsOrT runM defaultConnectionOptions (toServerAppT wsApp)) app req resp
