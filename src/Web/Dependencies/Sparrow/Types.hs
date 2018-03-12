{-# LANGUAGE
    DeriveGeneric
  , GeneralizedNewtypeDeriving
  , OverloadedStrings
  #-}

module Web.Dependencies.Sparrow.Types where

import Data.Hashable (Hashable)
import Data.Text (Text, pack, intercalate)
import Data.Aeson (ToJSON (..), FromJSON (..), Value (String))
import Data.Aeson.Attoparsec (attoAeson)
import Data.Attoparsec.Text (Parser, takeWhile1, char, sepBy)
import GHC.Generics (Generic)
import Control.Concurrent.Async (Async)


-- * Server

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



-- * Client

data ClientReturn m deltaIn = ClientReturn
  { clientSendCurrent   :: deltaIn -> m ()
  , clientSendBroadcast :: Broadcast m
  , clientUnsubscribe   :: m ()
  }

data ClientArgs m initIn deltaIn deltaOut = ClientArgs
  { clientReceive  :: ClientReturn m deltaIn -> deltaOut -> m ()
  , clientInitIn   :: initIn
  , clientOnReject :: m ()
  }

type Client m initIn initOut deltaIn deltaOut =
  (ClientArgs m initIn deltaIn deltaOut -> m (initOut, ClientReturn m deltaIn)) -> m ()


-- * Topic

newtype Topic = Topic {getTopic :: [Text]}
  deriving (Eq, Ord, Generic, Hashable, Show)

instance FromJSON Topic where
  parseJSON = attoAeson (Topic <$> breaker)
    where
      breaker :: Parser [Text]
      breaker = takeWhile1 (/= '/') `sepBy` char '/'

instance ToJSON Topic where
  toJSON (Topic xs) = String (intercalate "/" xs)


-- * Broadcast

type Broadcast m = Topic -> m (Maybe (Value -> Maybe (m ())))
