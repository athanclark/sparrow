module Web.Dependencies.Sparrow.Session where

import Data.UUID (UUID, fromString, toString)
import Data.Text (pack, unpack)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (String))
import Data.Aeson.Types (typeMismatch)


newtype SessionID = SessionID {getSessionID :: UUID}

instance FromJSON SessionID where
  parseJSON (String x) = case fromString (unpack x) of
    Just x -> pure (SessionID x)
    Nothing -> fail "Not a UUID"
  parseJSON x = typeMismatch "SessionID" x

instance ToJSON SessionID where
  toJSON (SessionID x) = toJSON (toString x)
