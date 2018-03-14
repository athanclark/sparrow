{-# LANGUAGE
    GeneralizedNewtypeDeriving
  , DeriveFunctor
  #-}

module Web.Dependencies.Sparrow.Client.Types where

import Web.Dependencies.Sparrow.Types (WSIncoming, WithTopic)

import Data.Aeson (Value)
import Control.Monad.Reader (ReaderT)
import Control.Monad.Trans (MonadTrans (..))


data Env m = Env
  { envSendDelta :: WSIncoming (WithTopic Value) -> m ()
  , envSendInit  :: {-WithSessionID-} Value -> m () -- thread back?
                    -- generate and pack in the registration
  }


newtype SparrowClientT m a = SparrowClientT
  { runSparrowServerT :: ReaderT (Env m) m a
  } deriving (Functor, Applicative, Monad)

instance MonadTrans SparrowClientT where
  lift = SparrowClientT . lift
