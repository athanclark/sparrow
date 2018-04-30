{-# LANGUAGE
    DeriveGeneric
  , GeneralizedNewtypeDeriving
  , OverloadedStrings
  , RecordWildCards
  , NamedFieldPuns
  #-}

module Web.Dependencies.Sparrow.Types where

import Web.Dependencies.Sparrow.Session (SessionID)

import Data.Hashable (Hashable)
import Data.Text (Text, intercalate, unpack)
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.ByteString.Lazy as LBS
import Data.Aeson (ToJSON (..), FromJSON (..), Value (String, Object), (.=), object, (.:))
import Data.Aeson.Types (typeMismatch)
import Data.Aeson.Attoparsec (attoAeson)
import Data.Attoparsec.Text (Parser, takeWhile1, char, sepBy)
import Control.Applicative ((<|>))
import Control.DeepSeq (NFData)
import Control.Concurrent.Async (Async)
import GHC.Generics (Generic)


-- * Conceptual

-- ** Server

data ServerArgs m deltaOut = ServerArgs
  { serverDeltaReject :: m ()
  , serverSendCurrent :: deltaOut -> m ()
  }

data ServerReturn m initOut deltaIn deltaOut = ServerReturn
  { serverInitOut   :: initOut
  , serverOnOpen    :: ServerArgs m deltaOut
                    -> m [Async ()]
    -- ^ invoked once, and should return a 'Control.Concurrent.Async.link'ed long-lived thread
    -- to kill when the subscription dies
  , serverOnReceive :: ServerArgs m deltaOut
                    -> deltaIn -> m () -- ^ invoked for each receive
  }

data ServerContinue m initOut deltaIn deltaOut = ServerContinue
  { serverContinue      :: Broadcast m -> m (ServerReturn m initOut deltaIn deltaOut)
  , serverOnUnsubscribe :: m ()
  }

type Server m initIn initOut deltaIn deltaOut =
  initIn -> m (Maybe (ServerContinue m initOut deltaIn deltaOut))


staticServer :: Monad m
             => (initIn -> m (Maybe initOut)) -- ^ Produce an initOut
             -> Server m initIn initOut JSONVoid JSONVoid
staticServer f initIn = do
  mInitOut <- f initIn
  case mInitOut of
    Nothing -> pure Nothing
    Just initOut -> pure $ Just ServerContinue
      { serverOnUnsubscribe = pure ()
      , serverContinue = \_ -> pure ServerReturn
        { serverInitOut = initOut
        , serverOnOpen = \ServerArgs{serverDeltaReject} -> do
            serverDeltaReject
            pure []
        , serverOnReceive = \_ _ -> pure ()
        }
      }



-- ** Client

data ClientReturn m initOut deltaIn = ClientReturn
  { clientSendCurrent   :: deltaIn -> m ()
  , clientInitOut       :: initOut
  , clientUnsubscribe   :: m ()
  }

data ClientArgs m initIn initOut deltaIn deltaOut = ClientArgs
  { clientReceive  :: ClientReturn m initOut deltaIn -> deltaOut -> m ()
  , clientInitIn   :: initIn
  , clientOnReject :: m () -- ^ Run if the server decides to randomly kick the client
  }

type Client m initIn initOut deltaIn deltaOut =
  ( ClientArgs m initIn initOut deltaIn deltaOut
    -> m (Maybe (ClientReturn m initOut deltaIn))
    ) -> m ()


staticClient :: Monad m
             => ((initIn -> m (Maybe initOut)) -> m ()) -- ^ Obtain an initOut
             -> Client m initIn initOut JSONVoid JSONVoid
staticClient f invoke = f $ \initIn -> do
  mReturn <- invoke ClientArgs
    { clientInitIn = initIn
    , clientReceive = \_ _ -> pure ()
    , clientOnReject = pure ()
    }
  case mReturn of
    Nothing -> pure Nothing
    Just ClientReturn{clientInitOut,clientUnsubscribe} -> do
      clientUnsubscribe
      pure (Just clientInitOut)



-- ** Topic

newtype Topic = Topic {getTopic :: [Text]}
  deriving (Eq, Ord, Generic, Hashable, NFData)

instance Show Topic where
  show (Topic x) = unpack (intercalate "/" x)

instance FromJSON Topic where
  parseJSON = attoAeson (Topic <$> breaker)
    where
      breaker :: Parser [Text]
      breaker = takeWhile1 (/= '/') `sepBy` char '/'

instance ToJSON Topic where
  toJSON (Topic xs) = String (intercalate "/" xs)


-- ** Broadcast

type Broadcast m = Topic -> m (Maybe (Value -> Maybe (m ())))


-- * JSON Encodings

data JSONVoid

instance ToJSON JSONVoid where
  toJSON _ = String ""

instance FromJSON JSONVoid where
  parseJSON = typeMismatch "JSONVoid"


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


data InitResponse a
  = InitBadEncoding !LBS.ByteString
  | InitDecodingError !String -- when manually decoding the content, casted
  | InitRejected
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


data WSHTTPResponse
  = NoSessionID
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

data WSOutgoing a
  = WSTopicsSubscribed [Topic]
  | WSTopicAdded !Topic
  | WSTopicRemoved !Topic
  | WSTopicRejected !Topic
  | WSDecodingError !String
  | WSOutgoing a
  deriving (Eq, Show, Generic)

instance NFData a => NFData (WSOutgoing a)

instance ToJSON a => ToJSON (WSOutgoing a) where
  toJSON x = case x of
    WSDecodingError e -> object ["error" .= object ["decoding" .= e]]
    WSTopicsSubscribed subs -> object ["subs" .= object ["init" .= subs]]
    WSTopicAdded sub -> object ["subs" .= object ["add" .= sub]]
    WSTopicRemoved sub -> object ["subs" .= object ["del" .= sub]]
    WSTopicRejected sub -> object ["subs" .= object ["reject" .= sub]]
    WSOutgoing y -> object ["content" .= y]

instance FromJSON a => FromJSON (WSOutgoing a) where
  parseJSON json = case json of
    Object o -> do
      let content = WSOutgoing <$> o .: "content"
          error' = do
            json' <- o .: "error"
            case json' of
              Object o' -> do
                let decodingError = WSDecodingError <$> o' .: "decoding"
                decodingError
              _ -> fail'
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
      content <|> error' <|> subs
    _ -> fail'
    where
      fail' = typeMismatch "WSOutgoing" json
