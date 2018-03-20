{-# LANGUAGE
    DeriveGeneric
  , OverloadedStrings
  #-}

module Lib where

import Data.Aeson (ToJSON (..), FromJSON (..), Value (String))
import Data.Aeson.Types (typeMismatch)
import GHC.Generics (Generic)



data InitIn = InitIn
  deriving (Eq, Show, Generic)

instance ToJSON InitIn where
  toJSON InitIn = String "InitIn"

instance FromJSON InitIn where
  parseJSON json = case json of
    String x
      | x == "InitIn" -> pure InitIn
      | otherwise -> typeMismatch "InitIn" json
    _ -> typeMismatch "InitIn" json

data InitOut = InitOut
  deriving (Eq, Show, Generic)

instance ToJSON InitOut where
  toJSON InitOut = String "InitOut"

instance FromJSON InitOut where
  parseJSON json = case json of
    String x
      | x == "InitOut" -> pure InitOut
      | otherwise -> typeMismatch "InitOut" json
    _ -> typeMismatch "InitOut" json

data DeltaIn = DeltaIn
  deriving (Eq, Show, Generic)

instance ToJSON DeltaIn where
  toJSON DeltaIn = String "DeltaIn"

instance FromJSON DeltaIn where
  parseJSON json = case json of
    String x
      | x == "DeltaIn" -> pure DeltaIn
      | otherwise -> typeMismatch "DeltaIn" json
    _ -> typeMismatch "DeltaIn" json

data DeltaOut = DeltaOut
  deriving (Eq, Show, Generic)

instance ToJSON DeltaOut where
  toJSON DeltaOut = String "DeltaOut"

instance FromJSON DeltaOut where
  parseJSON json = case json of
    String x
      | x == "DeltaOut" -> pure DeltaOut
      | otherwise -> typeMismatch "DeltaOut" json
    _ -> typeMismatch "DeltaOut" json
