{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  #-}

module Web.Dependencies.Sparrow.Server where

import Web.Dependencies.Sparrow.Session (SessionID)
import Web.Dependencies.Sparrow.Server.Types (SparrowServerT, tell', execSparrowServerT, Tries (..))

import Web.Routes.Nested (Match)
import Web.Routes.Nested.Match (UrlChunks)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), object, (.=), Value (Object, String))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (typeMismatch)
import Data.Trie.Pred.Interface.Types (Singleton (singleton))
import Network.Wai.Trans (MiddlewareT)
import Network.Wai.Middleware.ContentType.Json (jsonOnly)
import Network.WebSockets.Simple (WebSocketsApp)
import Network.HTTP.Types (status400)


data WithSessionID a = WithSessionID
  { withSessionIDSessionID :: SessionID
  , withSessionIDContent   :: a
  }

instance FromJSON a => FromJSON (WithSessionID a) where
  parseJSON (Object o) = WithSessionID <$> (o .: "sessionID") <*> (o .: "content")
  parseJSON x = typeMismatch "WithSessionID" x

data WithTopic a = WithTopic
  { withTopicTopic   :: [Text]
  , withTopicContent :: a
  }


data InitResponse a
  = InitBadRequest
  | InitResponse a

instance ToJSON a => ToJSON (InitResponse a) where
  toJSON x = case x of
    InitBadRequest -> object ["error" .= String "bad request"]
    InitResponse x -> object ["content" .= x]

data WSIncoming a
  = WSSessionID SessionID
  | WSUnsubscribe
    { wsUnsubscribeTopic :: [Text] -- FIXME represent as Path while encodded, maybe codify?
    }
  | WSIncoming a

data WSOutgoing a
  = WSTopicsSubscribed
    { wsTopicsSubscribed :: [[Text]] -- FIXME represent as Path while encoded, maybe codify?
    }
  | WSTopicsAdded
    { wsTopicsAdded      :: [[Text]] -- FIXME
    }
  | WSTopicsRemoved
    { wsTopicsRemoved    :: [[Text]] -- FIXME
    }
  | WSOutgoing a


-- | Called per-connection
register :: forall m initIn initOut deltaIn deltaOut
          . MonadIO m
         => [Text]
         -> Server m initIn initOut deltaIn deltaOut
         -> m (MiddlewareT m, WebSocketsApp m (WSIncoming receive) (WSOutgoing send))
register topic (Server f) = do
  -- FIXME server is actually pure
  -- ServerReturn
  --   { serverReceive
  --   , serverInit
  --   , serverOnUnsubscribe
  --   } <- f Server
  --            { serverSendCurrent = \deltaOut -> pure ()
  --            , serverSendBroadcast = \path -> pure (Just (\value -> Just (pure ())))
  --            }
  pure
    ( -- per-connection perspective
      \app req resp -> do
      b <- liftIO (strictRequestBody req)
      case Aeson.decode b of
        Nothing -> resp (jsonOnly InitBadRequest status400 [])
        Just WithSessionID
          { withSessionIDContent
          , withSessionIDSessionID
          } -> do
          -- check if currently subscribed, reject if connected especially, but definitely if active subscription is assumed for client
          case withSessionIDContent of
            WithTopic
              { withTopicTopic
              , withTopicContent
              } ->
    , -- per-connection perspective
      WebSocketsApp
      { onOpen = \WebSocketsAppParams{send,close} -> pure ()
      , onReceive = \WebSocketsAppParams{send,close} r -> case r of
          WSSessionID sessionID ->
            -- check if currently used by another channel, check if initialized, then register `send` function
      , onClose = \o e -> pure ()
      }
    )


match :: Monad m
      => Match xs' xs (MiddlewareT m) resultHttp
      => Match xs' xs (WebSocketsApp m receive send)  resultWebSocket
      => UrlChunks xs
      -> (MiddlewareT m, WebSocketsApp m receive send)
      -> SparrowServerT resultHttp resultWebSocket m ()
match ts (http,websocket) =
  tell' (Tries (singleton ts http) (singleton ts websocket))
