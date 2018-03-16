{-# LANGUAGE
    DeriveGeneric
  #-}

module Lib where

import Data.Aeson (ToJSON (toEncoding), FromJSON, genericToEncoding, defaultOptions)
import GHC.Generics (Generic)



data InitIn = InitIn
  deriving (Eq, Show, Generic)

instance ToJSON InitIn where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON InitIn

data InitOut = InitOut
  deriving (Eq, Show, Generic)

instance ToJSON InitOut where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON InitOut

data DeltaIn = DeltaIn
  deriving (Eq, Show, Generic)

instance ToJSON DeltaIn where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON DeltaIn

data DeltaOut = DeltaOut
  deriving (Eq, Show, Generic)

instance ToJSON DeltaOut where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON DeltaOut
