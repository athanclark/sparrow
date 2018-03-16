{-# LANGUAGE
    GeneralizedNewtypeDeriving
  , DeriveFunctor
  , NamedFieldPuns
  #-}

module Web.Dependencies.Sparrow.Client.Types where

import Web.Dependencies.Sparrow.Types (WSIncoming, WithTopic, Topic)

import Data.Aeson (Value)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Control.Monad.Trans.Reader (ReaderT (..))
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.IO.Class (MonadIO (..))
import Control.Concurrent.STM (STM, atomically, TVar, newTVarIO, writeTVar, readTVar, modifyTVar')


data ClientRefs m = ClientRefs
  { clientContinue :: Maybe Value {-initOut-} -> m ()
  }

type RegisteredTopicSubscriptions m =
  TVar
    ( HashMap Topic
        ( Value -> m () -- `deltaOut` received from init
        , m () -- onReject
        )
    )


registerSubscription :: Env m -> Topic -> (Value -> m ()) -> m () -> STM ()
registerSubscription Env{envSubscriptions} topic onDeltaOut onReject =
  modifyTVar' envSubscriptions (HM.insert topic (onDeltaOut,onReject))

removeSubscription :: Env m -> Topic -> STM ()
removeSubscription Env{envSubscriptions} topic =
  modifyTVar' envSubscriptions (HM.delete topic)

callReject :: MonadIO m => Env m -> Topic -> m ()
callReject Env{envSubscriptions} topic = do
  mOnReject <- liftIO $ atomically $ do
    xs <- readTVar envSubscriptions
    let x = HM.lookup topic xs
    modifyTVar' envSubscriptions (HM.delete topic)
    pure x
  case mOnReject of
    Nothing -> liftIO $ putStrLn $ "Error, received rejected topic " ++ show topic ++ " unexpectedly"
    Just (_,onReject) -> onReject

callOnReceive :: MonadIO m => Env m -> Topic -> Value -> m ()
callOnReceive Env{envSubscriptions} topic v = do
  xs <- liftIO $ atomically $ readTVar envSubscriptions
  case HM.lookup topic xs of
    Nothing -> liftIO $ putStrLn $ "Error, received deltaOut unexpectedly: " ++ show topic ++ ", " ++ show v
    Just (onReceive,_) -> onReceive v


data Env m = Env
  { envSendDelta     :: WSIncoming (WithTopic Value) -> m ()
  , envSendInit      :: Topic -> Value -> m (Maybe Value)
  , envSubscriptions :: {-# UNPACK #-} !(RegisteredTopicSubscriptions m)
  }


newtype SparrowClientT m a = SparrowClientT
  { runSparrowClientT :: ReaderT (Env m) m a
  } deriving (Functor, Applicative, Monad)

instance MonadTrans SparrowClientT where
  lift = SparrowClientT . lift


ask' :: Applicative m => SparrowClientT m (Env m)
ask' = SparrowClientT (ReaderT (\x -> pure x))
