{-# LANGUAGE
    DeriveGeneric
  , GeneralizedNewtypeDeriving
  , OverloadedStrings
  #-}

module Web.Dependencies.Sparrow.Types where

import Web.Dependencies.Sparrow.Session (SessionID)

import Data.Hashable (Hashable)
import Data.Text (Text, pack, intercalate)
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.ByteString.Lazy as LBS
import Data.Aeson (ToJSON (..), FromJSON (..), Value (String, Object), (.=), object, (.:))
import Data.Aeson.Types (typeMismatch)
import Data.Aeson.Attoparsec (attoAeson)
import Data.Attoparsec.Text (Parser, takeWhile1, char, sepBy)
import Control.Applicative ((<|>))
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
                    -> m (Maybe (Async ()))
    -- ^ only after initOut is provided can we send deltas - invoked once, and should
    -- return a totally 'Control.Concurrent.Async.link'ed thread (if spawned)
    -- to kill with the subscription dies
  , serverOnReceive :: ServerArgs m deltaOut
                    -> deltaIn -> m () -- ^ invoked for each receive
  }

data ServerContinue m initOut deltaIn deltaOut = ServerContinue
  { serverContinue      :: Broadcast m -> m (ServerReturn m initOut deltaIn deltaOut)
  , serverOnUnsubscribe :: m ()
  }

type Server m initIn initOut deltaIn deltaOut =
  initIn -> m (Maybe (ServerContinue m initOut deltaIn deltaOut))



-- ** Client

data ClientReturn m initOut deltaIn = ClientReturn
  { clientSendCurrent   :: deltaIn -> m Bool -- was vs. can't be successful?
  , clientInitOut       :: initOut
  , clientUnsubscribe   :: m ()
  }

data ClientArgs m initIn initOut deltaIn deltaOut = ClientArgs
  { clientReceive  :: ClientReturn m initOut deltaIn -> deltaOut -> m ()
  , clientInitIn   :: initIn
  , clientOnReject :: m ()
  }

type Client m initIn initOut deltaIn deltaOut =
  (ClientArgs m initIn initOut deltaIn deltaOut -> m (Maybe (ClientReturn m initOut deltaIn))) -> m ()


-- ** Topic

newtype Topic = Topic {getTopic :: [Text]}
  deriving (Eq, Ord, Generic, Hashable, Show)

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
    InitBadEncoding y -> object ["error" .= object ["badRequest" .= LT.decodeUtf8 y]]
    InitDecodingError y -> object ["error" .= object ["decoding" .= y]]
    InitRejected -> object ["error" .= String "rejected"]
    InitResponse y -> object ["content" .= y]

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
  = WSTopicsSubscribed [Topic]
  | WSTopicAdded Topic
  | WSTopicRemoved Topic
  | WSTopicRejected Topic
  | WSDecodingError String
  | WSOutgoing a

instance ToJSON a => ToJSON (WSOutgoing a) where
  toJSON x = case x of
    WSDecodingError e -> object ["error" .= object ["decoding" .= e]]
    WSTopicsSubscribed subs -> object ["subs" .= object ["init" .= subs]]
    WSTopicAdded sub -> object ["subs" .= object ["add" .= sub]]
    WSTopicRemoved sub -> object ["subs" .= object ["del" .= sub]]
    WSTopicRejected sub -> object ["subs" .= object ["reject" .= sub]]
    WSOutgoing y -> object ["content" .= y]
