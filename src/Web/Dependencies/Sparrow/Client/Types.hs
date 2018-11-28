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

module Web.Dependencies.Sparrow.Client.Types
  ( -- * Context
    SparrowClientT (..)
  , Env (..)
  , ask'
  , TopicSubscription, RegisteredTopicSubscriptions
  , -- * Internal Machinery
    registerSubscription, removeSubscription, callReject, callOnReceive
  , -- * Exceptions
    SparrowClientException (..)
  ) where

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

-- | Stored value representing functions necessary to facilitate an active connection
data TopicSubscription m = TopicSubscription
  { tSubOnDeltaOut :: Value -> m () -- ^ `deltaOut` received from init
  , tSubOnReject :: m () -- ^ onReject
  }

-- | Mapping of topics to internally stored machinery representing a topic connection
type RegisteredTopicSubscriptions m = TMapMVar Topic (TopicSubscription m)


registerSubscription :: Env m
                     -> Topic
                     -> (Value -> m ()) -- ^ onDeltaOut
                     -> m () -- ^ onReject
                     -> STM ()
registerSubscription Env{envSubscriptions} topic onDeltaOut onReject =
  TMapMVar.insert envSubscriptions topic (TopicSubscription onDeltaOut onReject)

removeSubscription :: Env m -> Topic -> STM ()
removeSubscription Env{envSubscriptions} =
  TMapMVar.delete envSubscriptions

-- | Blocks if a topic isn't stored yet - takes it once it's there
callReject :: MonadIO m => Env m -> Topic -> m ()
callReject Env{envSubscriptions} topic = do
  (TopicSubscription _ onReject) <- liftIO $ atomically $ TMapMVar.lookup envSubscriptions topic
  onReject

-- | Blocks if a topic isn't stored yet
callOnReceive :: MonadIO m => Env m -> Topic -> Value -> m ()
callOnReceive Env{envSubscriptions} topic v = do
  (TopicSubscription onReceive _) <- liftIO $ atomically $ TMapMVar.observe envSubscriptions topic
  onReceive v


-- * Context

-- | Shared value representing the stored machinery and functions to facilitate a connection
data Env m = Env
  { envSendDelta     :: WSIncoming (WithTopic Value) -> m () -- ^ Send a @deltaIn@ for a topic, after encoded
  , envSendInit      :: Topic -> Value -> m (Maybe Value) -- ^ Send a @initIn@ for a topic, after encoded
  , envSubscriptions :: {-# UNPACK #-} !(RegisteredTopicSubscriptions m) -- ^ Stored machinery
  }

-- | Represents a sparrow client being defined
newtype SparrowClientT m a = SparrowClientT
  { runSparrowClientT :: ReaderT (Env m) m a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadWriter w, MonadState s, MonadCatch, MonadThrow, MonadMask)
instance MonadReader r m => MonadReader r (SparrowClientT m) where
  ask = lift ask
  local f (SparrowClientT (ReaderT x)) = SparrowClientT $ ReaderT $ \r -> local f (x r)
instance MonadTrans SparrowClientT where
  lift = SparrowClientT . lift


ask' :: Applicative m => SparrowClientT m (Env m)
ask' = SparrowClientT (ReaderT pure)


-- * Exceptions


data SparrowClientException
  = InitOutFailed -- ^ Thrown by 'Web.Dependencies.Sparrow.Client.unpackClient'
  | InitOutDecodingError String -- ^ thrown by `Web.Dependencies.Sparrow.Client.unpackClient` and
                                -- 'Web.Dependencies.Sparrow.Client.allocateDependencies'
  | DeltaOutDecodingError String -- ^ thrown by `Web.Dependencies.Sparrow.Client.unpackClient`
  | InitOutHTTPError -- ^ thrown by `Web.Dependencies.Sparrow.Client.allocateDependencies`
  | UnexpectedAddedTopic Topic -- ^ thrown by `Web.Dependencies.Sparrow.Client.allocateDependencies`
  | UnexpectedRemovedTopic Topic -- ^ thrown by `Web.Dependencies.Sparrow.Client.allocateDependencies`
  deriving (Show, Generic)

instance Exception SparrowClientException

