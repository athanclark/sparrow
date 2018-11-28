{-# LANGUAGE
    DeriveGeneric
  , GeneralizedNewtypeDeriving
  , OverloadedStrings
  , RecordWildCards
  , NamedFieldPuns
  , RankNTypes
  #-}

{-|
Module: Web.Dependencies.Sparrow.Types
Copyright: (c) 2018 Athan Clark
License: BSD-3-Clause
Maintainer: athan.clark@gmail.com
Portability: GHC

A sparrow server in Haskell is described monadically - in Purescript, we stick
with the monomorphic @Effect@ monad to reduce the output code to something much more appealing,
but because GHC is so good at optimization, we choose to maintain a constraint on
'Control.Monad.Trans.Control.MonadBaseControl IO' to sustain compatability with effective
code, while being polymorphic in the application context.
-}

module Web.Dependencies.Sparrow.Types
  ( -- * Conceptual
    -- ** Server
    ServerArgs (..), hoistServerArgs
  , ServerReturn (..), hoistServerReturn
  , ServerContinue (..), hoistServerContinue
  , Server, hoistServer
  , -- ** Client
    ClientArgs (..), ClientReturn (..), Client
  , -- ** Topic
    Topic, topicToText, topicToRelFile
  , -- ** Session
    SessionID, newSessionID, sessionIDFromQueryString
  , -- ** Broadcast
    Broadcast
  , -- * Protocol
    WithSessionID (..), WithTopic (..), InitResponse (..), WSHTTPResponse (..)
  , WSIncoming (..), WSOutgoing (..)
  ) where

import Data.Hashable (Hashable)
import Data.Text (Text, intercalate, unpack)
import qualified Data.Text as T
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.ByteString.Lazy as LBS
import Data.Aeson (ToJSON (..), FromJSON (..), Value (String, Object), (.=), object, (.:))
import Data.Aeson.Types (typeMismatch)
import Data.Aeson.Attoparsec (attoAeson)
import Data.String (IsString (..))
import Data.Attoparsec.Text (Parser, takeWhile1, char, sepBy)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Data.UUID.V4 (nextRandom)
import Path (Path, Rel, File, parseRelFile)
import Control.Applicative ((<|>))
import Control.Monad (join)
import Control.DeepSeq (NFData)
import Control.Concurrent.Async (Async)
import Control.Concurrent.STM (TVar)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import Network.Wai (Request, queryString)


-- * Conceptual

-- ** Server

-- | Server-oriented arguments for interacting with a connected client.
data ServerArgs m deltaOut = ServerArgs
  { serverDeltaReject :: m () -- ^ Spontaneously kill the connected client's session
  , serverSendCurrent :: deltaOut -> m () -- ^ Generate @deltaOut@ data to send to the connected client
  }

hoistServerArgs :: (forall a. m a -> n a)
                -> ServerArgs m deltaOut
                -> ServerArgs n deltaOut
hoistServerArgs f ServerArgs{..} = ServerArgs
  { serverDeltaReject = f serverDeltaReject
  , serverSendCurrent = f . serverSendCurrent
  }


-- | Server's return value for a client's established connection
data ServerReturn m f initOut deltaIn deltaOut = ServerReturn
  { serverInitOut   :: initOut -- ^ Return value from @initIn@
  , serverOnOpen    :: ServerArgs m deltaOut
                    -> m (TVar (f (Async ())))
    -- ^ Invoked once, and should return a mutable set of threads
    -- to kill when the subscription dies
  , serverOnReceive :: ServerArgs m deltaOut
                    -> deltaIn -> m () -- ^ Invoked for each received @deltaIn@
  }

hoistServerReturn :: (forall a. m a -> n a)
                  -> (forall a. n a -> m a)
                  -> ServerReturn m f initOut deltaIn deltaOut
                  -> ServerReturn n f initOut deltaIn deltaOut
hoistServerReturn f g ServerReturn{..} = ServerReturn
  { serverInitOut
  , serverOnOpen = \args -> f $ serverOnOpen $ hoistServerArgs g args
  , serverOnReceive = \args deltaIn -> f $ serverOnReceive (hoistServerArgs g args) deltaIn
  }


-- | Server's intermediary return value - scoped for access to broadcasting and unsubscription.
data ServerContinue m f initOut deltaIn deltaOut = ServerContinue
  { serverContinue      :: Broadcast m -> m (ServerReturn m f initOut deltaIn deltaOut) -- ^ You can broadcast at any time after receiving an @initIn@
  , serverOnUnsubscribe :: m () -- ^ Handler for when a client kills their session
  }

hoistServerContinue :: Monad m
                    => (forall a. m a -> n a)
                    -> (forall a. n a -> m a)
                    -> ServerContinue m f initOut deltaIn deltaOut
                    -> ServerContinue n f initOut deltaIn deltaOut
hoistServerContinue f g ServerContinue{..} = ServerContinue
  { serverContinue = \bcast -> f $ hoistServerReturn f g <$> serverContinue (hoistBroadcast g bcast)
  , serverOnUnsubscribe = f serverOnUnsubscribe
  }


-- | Given an @initIn@, either reject immediately with 'Data.Maybe.Nothing', or accept the connection and continue with 'Data.Maybe.Just'.
type Server m f initIn initOut deltaIn deltaOut =
  initIn -> m (Maybe (ServerContinue m f initOut deltaIn deltaOut))

hoistServer :: Monad m => Monad n
            => (forall a. m a -> n a)
            -> (forall a. n a -> m a)
            -> Server m f initIn initOut deltaIn deltaOut
            -> Server n f initIn initOut deltaIn deltaOut
hoistServer f g server = \initIn -> do
  mCont <- f $ server initIn
  case mCont of
    Nothing -> pure Nothing
    Just cont -> pure $ Just $ hoistServerContinue f g cont





-- ** Client

-- | Client-oriented arguments for creating a sparrow session.
data ClientArgs m initIn initOut deltaIn deltaOut = ClientArgs
  { clientReceive  :: ClientReturn m initOut deltaIn -> deltaOut -> m () -- ^ Handler to call when spontaneously receiving @deltaOut@ data
  , clientInitIn   :: initIn -- ^ Initial value for starting the connection
  , clientOnReject :: m () -- ^ Handler to run if the server decides to randomly kick the client
  }

-- | Client's return value obtained from an invoked connection.
data ClientReturn m initOut deltaIn = ClientReturn
  { clientSendCurrent   :: deltaIn -> m () -- ^ Supply @deltaIn@ data to the connection
  , clientInitOut       :: initOut -- ^ The @initOut@ data received by the server
  , clientUnsubscribe   :: m () -- ^ Kill the connection
  }

-- | Given the ability to invoke a connection, possibly returning more connection functionality if it's successful, possibly use it.
-- Warning: Sparrow connections are designed to be /singletons/ - at most, only one topic active at a time, per client! It's up to you to maintain consistency.
type Client m initIn initOut deltaIn deltaOut =
  ( ClientArgs m initIn initOut deltaIn deltaOut
    -> m (Maybe (ClientReturn m initOut deltaIn))
    ) -> m ()




-- ** Topic

newtype Topic = Topic {getTopic :: [Text]}
  deriving (Eq, Ord, Generic, Hashable, NFData)

topicToText :: Topic -> Text
topicToText (Topic t) = intercalate "/" t

topicToRelFile :: Topic -> Path Rel File
topicToRelFile t = unsafePerformIO $ parseRelFile $ show t

instance IsString Topic where
  fromString x' =
    let loop x = case T.breakOn "/" x of
          (l,r)
            | r == "" -> []
            | otherwise -> l : loop (T.drop 1 r)
    in  Topic $ loop $ T.pack x'
instance Show Topic where
  show t = unpack (topicToText t)
instance FromJSON Topic where
  parseJSON = attoAeson (Topic <$> breaker)
    where
      breaker :: Parser [Text]
      breaker = takeWhile1 (/= '/') `sepBy` char '/'
instance ToJSON Topic where
  toJSON t = String (topicToText t)


-- ** Broadcast

-- | Obtain the broadcasting function for all clients connected to a topic.
type Broadcast m = Topic -> m (Maybe (Value -> Maybe (m ())))

hoistBroadcast :: Monad n => (forall a. m a -> n a) -> Broadcast m -> Broadcast n
hoistBroadcast f bcast = \topic -> do
  mResolve <- f (bcast topic)
  case mResolve of
    Nothing -> pure Nothing
    Just resolve -> pure $ Just $ \v -> f <$> resolve v



-- * JSON Encodings


-- | For sorting clients
data WithSessionID a = WithSessionID
  { withSessionIDSessionID :: {-# UNPACK #-} !SessionID
  , withSessionIDContent   :: a
  } deriving (Eq, Show, Generic)
instance NFData a => NFData (WithSessionID a)
instance ToJSON a => ToJSON (WithSessionID a) where
  toJSON WithSessionID{..} = object
    [ "sessionID" .= withSessionIDSessionID
    , "content" .= withSessionIDContent
    ]
instance FromJSON a => FromJSON (WithSessionID a) where
  parseJSON (Object o) = WithSessionID <$> (o .: "sessionID") <*> (o .: "content")
  parseJSON x = typeMismatch "WithSessionID" x

-- | For sorting topics
data WithTopic a = WithTopic
  { withTopicTopic   :: !Topic
  , withTopicContent :: a
  } deriving (Eq, Show, Generic)
instance NFData a => NFData (WithTopic a)
instance ToJSON a => ToJSON (WithTopic a) where
  toJSON WithTopic{..} = object
    [ "topic" .= withTopicTopic
    , "content" .= withTopicContent
    ]
instance FromJSON a => FromJSON (WithTopic a) where
  parseJSON (Object o) = WithTopic <$> (o .: "topic") <*> (o .: "content")
  parseJSON x = typeMismatch "WithTopic" x


-- | HTTP-level response from a server, to a client.
data InitResponse a
  = InitBadEncoding !LBS.ByteString -- ^ Failed decoding a 'Data.Aeson.Value' to a topic-specific type
  | InitDecodingError !String -- ^ When manually decoding the content, casted
  | InitRejected -- ^ When a server returns an initial 'Data.Maybe.Nothing'
  | InitResponse a
  deriving (Eq, Show, Generic)
instance NFData a => NFData (InitResponse a)
instance ToJSON a => ToJSON (InitResponse a) where
  toJSON x = case x of
    InitBadEncoding y -> object ["error" .= object ["badRequest" .= LT.decodeUtf8 y]]
    InitDecodingError y -> object ["error" .= object ["decoding" .= y]]
    InitRejected -> object ["error" .= String "rejected"]
    InitResponse y -> object ["content" .= y]
instance FromJSON a => FromJSON (InitResponse a) where
  parseJSON json = case json of
    Object o -> do
      let error' = do
            json' <- o .: "error"
            case json' of
              String x
                | x == "rejected" -> pure InitRejected
                | otherwise -> fail'
              Object o' -> do
                let badEncoding = (InitBadEncoding . LT.encodeUtf8) <$> o' .: "badRequest"
                    decodingError = InitDecodingError <$> o' .: "decoding"
                badEncoding <|> decodingError
              _ -> fail'
          response = InitResponse <$> o .: "content"
      error' <|> response
    _ -> fail'
    where
      fail' = typeMismatch "InitResponse" json


-- | An HTTP exception for an established sparrow websocket attempt
data WSHTTPResponse
  = NoSessionID -- ^ Thrown by 'Web.Dependencies.Sparrow.Server.serveDependencies'
  deriving (Eq, Show, Generic)
instance NFData WSHTTPResponse
instance ToJSON WSHTTPResponse where
  toJSON x = case x of
    NoSessionID -> object ["error" .= String "no sessionID query parameter"]
instance FromJSON WSHTTPResponse where
  parseJSON json = case json of
    Object o -> do
      json' <- o .: "error"
      case json' of
        String x
          | x == "no sessionID query parameter" -> pure NoSessionID
          | otherwise -> fail'
        _ -> fail'
    _ -> fail'
    where
      fail' = typeMismatch "WSHTTPResponse" json


-- | WebSocket messages going from the client, to the server.
data WSIncoming a
  = WSUnsubscribe
    { wsUnsubscribeTopic :: !Topic
    }
  | WSIncoming a
  deriving (Eq, Show, Generic)
instance NFData a => NFData (WSIncoming a)
instance ToJSON a => ToJSON (WSIncoming a) where
  toJSON x = case x of
    WSUnsubscribe topic -> object ["unsubscribe" .= topic]
    WSIncoming y -> object ["content" .= y]
instance FromJSON a => FromJSON (WSIncoming a) where
  parseJSON (Object o) = do
    let unsubscribe = WSUnsubscribe <$> o .: "unsubscribe"
        incoming = WSIncoming <$> o .: "content"
    unsubscribe <|> incoming
  parseJSON x = typeMismatch "WSIncoming" x


-- | WebSocket messages going from the server, to the client.
data WSOutgoing a
  = WSTopicsSubscribed [Topic] -- ^ Initial set of actively subscribed topics that a client should acknowledge
  | WSTopicAdded !Topic
  | WSTopicRemoved !Topic
  | WSTopicRejected !Topic -- ^ Communicate a server-originating rejection
  | WSOutgoing a
  deriving (Eq, Show, Generic)
instance NFData a => NFData (WSOutgoing a)
instance ToJSON a => ToJSON (WSOutgoing a) where
  toJSON x = case x of
    WSTopicsSubscribed subs -> object ["subs" .= object ["init" .= subs]]
    WSTopicAdded sub -> object ["subs" .= object ["add" .= sub]]
    WSTopicRemoved sub -> object ["subs" .= object ["del" .= sub]]
    WSTopicRejected sub -> object ["subs" .= object ["reject" .= sub]]
    WSOutgoing y -> object ["content" .= y]
instance FromJSON a => FromJSON (WSOutgoing a) where
  parseJSON json = case json of
    Object o -> do
      let content = WSOutgoing <$> o .: "content"
          subs = do
            json' <- o .: "subs"
            case json' of
              Object o' -> do
                let subsInit = WSTopicsSubscribed <$> o' .: "init"
                    subAdd = WSTopicAdded <$> o' .: "add"
                    subDel = WSTopicRemoved <$> o' .: "del"
                    subReject = WSTopicRejected <$> o' .: "reject"
                subsInit <|> subAdd <|> subDel <|> subReject
              _ -> fail'
      content <|> subs
    _ -> fail'
    where
      fail' = typeMismatch "WSOutgoing" json



-- | Individual client identifier.
newtype SessionID = SessionID {getSessionID :: UUID}
  deriving (Eq, Hashable, Generic, NFData)
instance Show SessionID where
  show (SessionID x) = UUID.toString x
instance FromJSON SessionID where
  parseJSON (String x) = case UUID.fromString (unpack x) of
    Just y -> pure (SessionID y)
    Nothing -> fail "Not a UUID"
  parseJSON x = typeMismatch "SessionID" x
instance ToJSON SessionID where
  toJSON x = toJSON (show x)


newSessionID :: IO SessionID
newSessionID = SessionID <$> nextRandom


sessionIDFromQueryString :: Request -> Maybe SessionID
sessionIDFromQueryString req =
  SessionID <$> (join (lookup "sessionID" (queryString req)) >>= UUID.fromASCIIBytes)
