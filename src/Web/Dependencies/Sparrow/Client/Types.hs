{-# LANGUAGE
    GeneralizedNewtypeDeriving
  , DeriveFunctor
  , DeriveGeneric
  , NamedFieldPuns
  , FlexibleInstances
  , UndecidableInstances
  , MultiParamTypeClasses
  , TypeFamilies
  #-}

module Web.Dependencies.Sparrow.Client.Types where

import Web.Dependencies.Sparrow.Types (WSIncoming, WithTopic, Topic)

import Data.Aeson (Value)
import Control.Monad.Reader (ReaderT (..), MonadReader (..))
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Writer (MonadWriter)
import Control.Monad.State (MonadState)
import Control.Monad.Catch (MonadCatch, MonadThrow, MonadMask, Exception)
import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TMapMVar (TMapMVar)
import qualified Control.Concurrent.STM.TMapMVar as TMapMVar
import GHC.Generics (Generic)



-- * Internal Machinery

type RegisteredTopicSubscriptions m =
  TMapMVar Topic
    ( Value -> m () -- `deltaOut` received from init
    , m () -- onReject
    )


registerSubscription :: Env m -> Topic -> (Value -> m ()) -> m () -> STM ()
registerSubscription Env{envSubscriptions} topic onDeltaOut onReject =
  TMapMVar.insert envSubscriptions topic (onDeltaOut,onReject)

removeSubscription :: Env m -> Topic -> STM ()
removeSubscription Env{envSubscriptions} =
  TMapMVar.delete envSubscriptions

callReject :: MonadIO m => Env m -> Topic -> m ()
callReject Env{envSubscriptions} topic = do
  (_,onReject) <- liftIO $ atomically $ TMapMVar.lookup envSubscriptions topic
  onReject

callOnReceive :: MonadIO m => Env m -> Topic -> Value -> m ()
callOnReceive Env{envSubscriptions} topic v = do
  (onReceive,_) <- liftIO $ atomically $ TMapMVar.observe envSubscriptions topic
  onReceive v


-- * Context

newtype SparrowClientT m a = SparrowClientT
  { runSparrowClientT :: ReaderT (Env m) m a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadWriter w, MonadState s, MonadCatch, MonadThrow, MonadMask)

instance MonadReader r m => MonadReader r (SparrowClientT m) where
  ask = lift ask
  local f (SparrowClientT (ReaderT x)) = SparrowClientT $ ReaderT $ \r -> local f (x r)

instance MonadTrans SparrowClientT where
  lift = SparrowClientT . lift

data Env m = Env
  { envSendDelta     :: WSIncoming (WithTopic Value) -> m ()
  , envSendInit      :: Topic -> Value -> m (Maybe Value)
  , envSubscriptions :: {-# UNPACK #-} !(RegisteredTopicSubscriptions m)
  }

ask' :: Applicative m => SparrowClientT m (Env m)
ask' = SparrowClientT (ReaderT pure)


-- * Exceptions


data SparrowClientException
  = InitOutFailed
  | InitOutDecodingError String
  | DeltaOutDecodingError String
  | InitOutHTTPError
  | UnexpectedAddedTopic Topic
  | UnexpectedRemovedTopic Topic
  | NetworkingDecodingError String
  deriving (Show, Generic)

instance Exception SparrowClientException

