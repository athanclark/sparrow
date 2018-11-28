{-# LANGUAGE
    GeneralizedNewtypeDeriving
  , DeriveFunctor
  , DeriveGeneric
  , TupleSections
  , RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  , FlexibleInstances
  , MultiParamTypeClasses
  , UndecidableInstances
  #-}

module Web.Dependencies.Sparrow.Server.Types
  ( -- * Context
    SparrowServerT
  , Env
  , newEnv
  , execSparrowServerT
  , execSparrowServerT'
  , tell'
  , ask'
  , SessionsOutgoing
  , RegisteredReceive
  , RegisteredTopicInvalidators
  , RegisteredTopicSubscribers
  , RegisteredOnUnsubscribe
  , RegisteredOnOpenThreads
  , -- * Internal Machinery
    -- ** Outgoing Per-Session
    unsafeBroadcastTopic
  , unsafeRegisterReceive
  , sendTo
  , getSent
  , -- ** Continuation Registration
    registerOnUnsubscribe
  , registerInvalidator
  , broadcaster
  , getCurrentRegisteredTopics
  , getCallReceive
  , callOnUnsubscribe
  , callAllOnUnsubscribe
  , -- ** Thread Management
    registerOnOpenThreads
  , killOnOpenThreads
  , killAllOnOpenThreads
  , -- ** Bookkeeping
    unregisterReceive
  , unregisterSession
  , addSubscriber
  , delSubscriber
  , delSubscriberFromAllTopics
  , -- * Exceptions
    SparrowServerException (..)
  ) where

import Web.Dependencies.Sparrow.Types (Topic, Broadcast, WithTopic (..), WSOutgoing (WSOutgoing), SessionID)

import Data.Text (Text)
import Data.Trie.Pred.Base (RootedPredTrie)
import Data.Monoid ((<>))
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Foldable (sequenceA_, asum)
import Data.Aeson (FromJSON, Value)
import qualified Data.Aeson as Aeson
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.HashSet (HashSet)
import qualified Data.HashSet as HS
import Control.Applicative (Alternative)
import Control.Monad (forM_)
import Control.Monad.Reader (ReaderT (..), runReaderT, ask, MonadReader (..))
import Control.Monad.State (StateT, execStateT, modify', MonadState (..))
import Control.Monad.Writer (MonadWriter)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans (MonadTrans (lift))
import Control.Monad.Catch (Exception, MonadCatch, MonadThrow, MonadMask)
import Control.Concurrent.Async (Async, cancel)
import Control.Concurrent.STM (STM, atomically, TVar, newTVarIO, readTVar, modifyTVar')
import Control.Concurrent.STM.TMapChan.Hash (TMapChan, newTMapChan)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import Control.Concurrent.STM.TMapMVar.Hash (TMapMVar, newTMapMVar)
import qualified Control.Concurrent.STM.TMapMVar.Hash as TMapMVar
import GHC.Generics (Generic)



-- | Mapping of client connections to outgoing, serialized Json messages, in the sparrow protocol.
type SessionsOutgoing = TMapChan SessionID (WSOutgoing (WithTopic Value))

-- | Add a message to the queue for a specific client.
sendTo :: Env f m -> SessionID -> WSOutgoing (WithTopic Value) -> STM ()
sendTo Env{envSessionsOutgoing} =
  TMapChan.insert envSessionsOutgoing

getSent :: Env f m -> SessionID -> STM (WSOutgoing (WithTopic Value))
getSent Env{envSessionsOutgoing} =
  TMapChan.lookup envSessionsOutgoing


-- | Mapping of a single receivable function, for accepting @deltaIn@ messages.
type RegisteredReceive m = TMapMVar SessionID (TMapMVar Topic (Value -> Maybe (m ())))


-- | Unsafe because receiver isn't type-caste to the expected Topic
unsafeRegisterReceive :: MonadIO m
                      => Env f m -> SessionID -> Topic -> (Value -> Maybe (m ())) -> STM ()
unsafeRegisterReceive Env{envRegisteredReceive} sID topic f = do
  mTopics <- TMapMVar.tryObserve envRegisteredReceive sID
  case mTopics of
    Nothing -> do
      topics <- newTMapMVar
      TMapMVar.insert topics topic f
      TMapMVar.insert envRegisteredReceive sID topics
    Just topics ->
      TMapMVar.insertForce topics topic f

-- | Remove a @deltaIn@ handler from the server for a specific topic
unregisterReceive :: Env f m -> SessionID -> Topic -> STM ()
unregisterReceive Env{envRegisteredReceive} sID topic = do
  mTopics <- TMapMVar.tryObserve envRegisteredReceive sID
  case mTopics of
    Nothing -> pure ()
    Just topics -> TMapMVar.delete topics topic

-- | Remove an entire connection from the server
unregisterSession :: Env f m -> SessionID -> STM ()
unregisterSession Env{envRegisteredReceive} =
  TMapMVar.delete envRegisteredReceive

-- | Blocks until the receiver is available - applies the receiver to the value supplied.
getCallReceive :: MonadIO m
               => Env f m -> SessionID -> Topic -> Value -> STM (Maybe (m ()))
getCallReceive Env{envRegisteredReceive} sID topic v = do
  topics <- TMapMVar.observe envRegisteredReceive sID
  onReceive <- TMapMVar.observe topics topic
  pure (onReceive v)

-- | Get the currently active topics for a connection
getCurrentRegisteredTopics :: Env f m -> SessionID -> STM [Topic]
getCurrentRegisteredTopics Env{envRegisteredReceive} sID = do
  mTopics <- TMapMVar.tryObserve envRegisteredReceive sID
  case mTopics of
    Nothing -> pure []
    Just topics -> TMapMVar.keys topics

-- | Set of Json deserializers for various topics, for @deltaIn@ values
type RegisteredTopicInvalidators = TVar (HashMap Topic (Value -> Maybe String))

-- | Register a type @deltaIn@'s' 'Data.Aeson.FromJSON' instance as a deserializer for a topic.
registerInvalidator :: forall deltaIn f m
                     . FromJSON deltaIn
                    => Env f m -> Topic -> Proxy deltaIn -> STM ()
registerInvalidator Env{envRegisteredTopicInvalidators} topic Proxy =
  let go v = case Aeson.fromJSON v of
              Aeson.Error e -> Just e
              Aeson.Success (_ :: deltaIn) -> Nothing
  in  modifyTVar' envRegisteredTopicInvalidators (HM.insert topic go)

-- | Get a deserializer for a topic
getInvalidator :: Env f m -> Topic -> STM (Maybe (Value -> Maybe String))
getInvalidator Env{envRegisteredTopicInvalidators} topic =
  HM.lookup topic <$> readTVar envRegisteredTopicInvalidators

-- | Set of active connections for a topic
type RegisteredTopicSubscribers = TVar (HashMap Topic (HashSet SessionID))

-- | Acknowledge a connection as active for a topic
addSubscriber :: Env f m -> Topic -> SessionID -> STM ()
addSubscriber Env{envRegisteredTopicSubscribers} topic sID =
  modifyTVar' envRegisteredTopicSubscribers
    (HM.alter (Just . maybe (HS.singleton sID) (HS.insert sID)) topic)

-- | Delete a connection from the topic's connection set
delSubscriber :: Env f m -> Topic -> SessionID -> STM ()
delSubscriber Env{envRegisteredTopicSubscribers} topic sID =
  let go xs
        | xs == HS.singleton sID = Nothing
        | otherwise = Just (HS.delete sID xs)
  in  modifyTVar' envRegisteredTopicSubscribers
        (HM.alter (maybe Nothing go) topic)

-- | Removes a subscriber from every topic - for deleted connections
delSubscriberFromAllTopics :: Env f m -> SessionID -> STM ()
delSubscriberFromAllTopics env@Env{envRegisteredTopicSubscribers} sID = do
  allTopics <- HM.keys <$> readTVar envRegisteredTopicSubscribers
  forM_ allTopics (\topic -> delSubscriber env topic sID)

-- | Get all subscribers for a topic - for broadcasting
getSubscribers :: Env f m -> Topic -> STM [SessionID]
getSubscribers Env{envRegisteredTopicSubscribers} topic =
  maybe [] HS.toList . HM.lookup topic <$> readTVar envRegisteredTopicSubscribers

-- | Server's @onUnsubscribe@ handlers for each topic, per connection.
type RegisteredOnUnsubscribe m = TVar (HashMap SessionID (HashMap Topic (m ())))

-- | Add an @onUnsubscribe@ handler to the set
registerOnUnsubscribe :: Env f m -> SessionID -> Topic -> m () -> STM ()
registerOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID topic eff = do
  xs <- readTVar envRegisteredOnUnsubscribe
  let topics = fromMaybe HM.empty (HM.lookup sID xs)
  modifyTVar' envRegisteredOnUnsubscribe (HM.insert sID (HM.insert topic eff topics))

-- | Invoke an @onUnsubscribe@ handler
callOnUnsubscribe :: MonadIO m => Env f m -> SessionID -> Topic -> m ()
callOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID topic = do
  mEff <- liftIO $ atomically $ do
    xs <- readTVar envRegisteredOnUnsubscribe
    case HM.lookup sID xs of
      Nothing -> pure Nothing
      Just topics -> do
        let x = HM.lookup topic topics
        modifyTVar' envRegisteredOnUnsubscribe (HM.adjust (HM.delete topic) sID)
        pure x
  fromMaybe (pure ()) mEff

-- | Invoke every topic's @onUnsubscribe@ handler for a connection - when it get's killed.
callAllOnUnsubscribe :: MonadIO m => Env f m -> SessionID -> m ()
callAllOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID = do
  effs <- liftIO $ atomically $ do
    xs <- readTVar envRegisteredOnUnsubscribe
    case HM.lookup sID xs of
      Nothing -> pure []
      Just topics -> do
        let effs = HM.elems topics
        modifyTVar' envRegisteredOnUnsubscribe (HM.delete sID)
        pure effs
  sequenceA_ effs


-- | Active threads for each connection - which may be spontaneously sending @deltaOut@s.
type RegisteredOnOpenThreads f =
  TVar (HashMap SessionID (HashMap Topic (TVar (f (Async ())))))


-- | Adds a mutable set of threads to the mapping
registerOnOpenThreads :: Env f m -> SessionID -> Topic -> TVar (f (Async ())) -> STM ()
registerOnOpenThreads Env{envRegisteredOnOpenThreads} sID topic thread = do
  xs <- readTVar envRegisteredOnOpenThreads
  let topics = fromMaybe HM.empty (HM.lookup sID xs)
  modifyTVar' envRegisteredOnOpenThreads
    (HM.insert sID (HM.insert topic thread topics))

-- | Kill the threads sending data to a topic
killOnOpenThreads :: Foldable f => MonadIO m => Env f m -> SessionID -> Topic -> IO ()
killOnOpenThreads Env{envRegisteredOnOpenThreads} sID topic = do
  mThread <- atomically $ do
    xs <- readTVar envRegisteredOnOpenThreads
    mThreads' <- case HM.lookup sID xs of
      Nothing -> pure Nothing
      Just topics -> do
        let x = HM.lookup topic topics
        modifyTVar' envRegisteredOnOpenThreads (HM.adjust (HM.delete topic) sID)
        pure x
    case mThreads' of
      Nothing -> pure Nothing
      Just threadsRef -> Just <$> readTVar threadsRef
  case mThread of
    Nothing -> pure ()
    Just threads -> mapM_ cancel threads

-- | Kill all threads for every topic communicating with a connection.
killAllOnOpenThreads :: Foldable f => Alternative f => MonadIO m => Env f m -> SessionID -> IO ()
killAllOnOpenThreads Env{envRegisteredOnOpenThreads} sID = do
  threads <- atomically $ do
    xs <- readTVar envRegisteredOnOpenThreads
    threadRefs <- case HM.lookup sID xs of
      Nothing -> pure []
      Just topics -> do
        let x = HM.elems topics
        modifyTVar' envRegisteredOnOpenThreads (HM.delete sID)
        pure x
    mapM readTVar threadRefs
  forM_ (asum threads) cancel


-- | A server's environment for internal machinery
data Env f m = Env
  { envSessionsOutgoing            :: {-# UNPACK #-} !SessionsOutgoing
  , envRegisteredReceive           :: {-# UNPACK #-} !(RegisteredReceive m)
  , envRegisteredTopicInvalidators :: {-# UNPACK #-} !RegisteredTopicInvalidators
  , envRegisteredTopicSubscribers  :: {-# UNPACK #-} !RegisteredTopicSubscribers
  , envRegisteredOnUnsubscribe     :: {-# UNPACK #-} !(RegisteredOnUnsubscribe m)
  , envRegisteredOnOpenThreads     :: {-# UNPACK #-} !(RegisteredOnOpenThreads f)
  }


newEnv :: IO (Env f m)
newEnv = Env
  <$> atomically newTMapChan
  <*> atomically newTMapMVar
  <*> newTVarIO HM.empty
  <*> newTVarIO HM.empty
  <*> newTVarIO HM.empty
  <*> newTVarIO HM.empty

-- | Unsafe because the @deltaOut@ value isn't validated
unsafeBroadcastTopic :: MonadIO m => Env f m -> Topic -> Value -> m ()
unsafeBroadcastTopic env t v =
  liftIO $ atomically $ do
    ss <- getSubscribers env t
    forM_ ss (\sessionID -> sendTo env sessionID (WSOutgoing (WithTopic t v)))

-- | Safe broadcast
broadcaster :: MonadIO m => Env f m -> Broadcast m
broadcaster env = \topic -> do
  mInvalidator <- liftIO $ atomically $ getInvalidator env topic
  case mInvalidator of
    Nothing -> pure Nothing
    Just invalidator -> pure $ Just $ \v -> case invalidator v of
      Just _ -> Nothing -- is invalid
      Nothing -> Just (unsafeBroadcastTopic env topic v)


-- | Monoid for WriterT (as StateT)
type Paper http = RootedPredTrie Text http


-- | Builder for a sparrow server - a hierarchical set of topic handlers
newtype SparrowServerT http f m a = SparrowServerT
  { runSparrowServerT :: ReaderT (Env f m) (StateT (Paper http) m) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadWriter w, MonadCatch, MonadThrow, MonadMask)
instance MonadTrans (SparrowServerT http f) where
  lift x = SparrowServerT (lift (lift x))
instance MonadReader r m => MonadReader r (SparrowServerT http f m) where
  ask = lift ask
  local f (SparrowServerT (ReaderT g)) = SparrowServerT $ ReaderT $ \env -> local f (g env)
instance MonadState s m => MonadState s (SparrowServerT http f m) where
  get = lift get
  put x = lift (put x)


data SparrowServerException
  = NoHandlerForTopic Topic -- ^ Thrown by 'Web.Dependencies.Sparrow.Server.serveDependencies'
  deriving (Show, Generic)
instance Exception SparrowServerException


-- | Run the sparrow builder
execSparrowServerT :: MonadIO m
                   => SparrowServerT http f m a
                   -> m (Paper http, Env f m)
execSparrowServerT x = do
  env <- liftIO newEnv
  (,env) <$> execSparrowServerT' env x

execSparrowServerT' :: Monad m
                    => Env f m
                    -> SparrowServerT http f m a
                    -> m (Paper http)
execSparrowServerT' env (SparrowServerT x) =
  execStateT (runReaderT x env) mempty


tell' :: Monad m => Paper http -> SparrowServerT http f m ()
tell' x = SparrowServerT (lift (modify' (<> x)))

ask' :: Monad m => SparrowServerT http f m (Env f m)
ask' = SparrowServerT ask
