{-# LANGUAGE
    GeneralizedNewtypeDeriving
  , DeriveFunctor
  , TupleSections
  , RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  #-}

module Web.Dependencies.Sparrow.Server.Types
  ( SparrowServerT
  , Env (..)
  , execSparrowServerT
  , execSparrowServerT'
  , tell'
  , ask'
  , unsafeBroadcastTopic
  , unsafeSendTo
  , registerOnUnsubscribe
  , broadcaster
  ) where

import Web.Dependencies.Sparrow.Types (Topic (..), Broadcast)
import Web.Dependencies.Sparrow.Session (SessionID)

import Data.Text (Text)
import Data.Trie.Pred.Base (RootedPredTrie)
import Data.Monoid ((<>))
import Data.Proxy (Proxy (..))
import Data.Foldable (sequenceA_)
import Data.Aeson (FromJSON, Value)
import qualified Data.Aeson as Aeson
import qualified ListT as ListT
import Control.Monad (forM_)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.State (StateT, execStateT, modify')
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans (MonadTrans (lift))
import Control.Concurrent.Async (Async, cancel)
import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TMapChan.Hash (TMapChan, newTMapChan)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import qualified STMContainers.Map as STMMap
import qualified STMContainers.Multimap as STMMultimap



type SessionsOutgoing = TMapChan SessionID Value

unsafeSendTo :: Env m -> SessionID -> Value -> STM ()
unsafeSendTo Env{envSessionsOutgoing} sID v =
  TMapChan.insert envSessionsOutgoing sID v


type RegisteredReceive m = STMMap.Map SessionID (STMMap.Map Topic (Value -> Maybe (m ())))

unsafeRegisterReceive :: MonadIO m
                      => Env m -> SessionID -> Topic -> (Value -> Maybe (m ())) -> STM ()
unsafeRegisterReceive Env{envRegisteredReceive} sID topic f = do
  mTopics <- STMMap.lookup sID envRegisteredReceive
  topics <- case mTopics of
    Nothing -> do
      x <- STMMap.new
      STMMap.insert x sID envRegisteredReceive
      pure x
    Just x -> pure x
  STMMap.insert f topic topics

getCallReceive :: MonadIO m
               => Env m -> SessionID -> Topic -> Value -> STM (Maybe (m ()))
getCallReceive Env{envRegisteredReceive} sID topic v = do
  mTopics <- STMMap.lookup sID envRegisteredReceive
  case mTopics of
    Nothing -> pure Nothing
    Just topics -> do
      mOnReceive <- STMMap.lookup topic topics
      case mOnReceive of
        Nothing -> pure Nothing
        Just onReceive -> pure (onReceive v)

type RegisteredTopicInvalidators = STMMap.Map Topic (Value -> Maybe String)

registerInvalidator :: forall deltaIn m
                     . FromJSON deltaIn
                    => Env m -> Topic -> Proxy deltaIn -> STM ()
registerInvalidator Env{envRegisteredTopicInvalidators} topic Proxy =
  STMMap.insert (\v -> case Aeson.fromJSON v of
                    Aeson.Error e -> Just e
                    Aeson.Success (x :: deltaIn) -> Nothing
                ) topic envRegisteredTopicInvalidators

getValidator :: Env m -> Topic -> STM (Maybe (Value -> Maybe String))
getValidator Env{envRegisteredTopicInvalidators} topic =
  STMMap.lookup topic envRegisteredTopicInvalidators

type RegisteredTopicSubscribers = STMMultimap.Multimap Topic SessionID

addSubscriber :: Env m -> Topic -> SessionID -> STM ()
addSubscriber Env{envRegisteredTopicSubscribers} topic sID =
  STMMultimap.insert sID topic envRegisteredTopicSubscribers

delSubscriber :: Env m -> Topic -> SessionID -> STM ()
delSubscriber Env{envRegisteredTopicSubscribers} topic sID =
  STMMultimap.delete sID topic envRegisteredTopicSubscribers

delSubscriberFromAllTopics :: Env m -> SessionID -> STM ()
delSubscriberFromAllTopics env@Env{envRegisteredTopicSubscribers} sID = do
  allTopics <- ListT.toReverseList (STMMultimap.streamKeys envRegisteredTopicSubscribers)
  forM_ allTopics (\topic -> delSubscriber env topic sID)

getSubscribers :: Env m -> Topic -> STM [SessionID]
getSubscribers Env{envRegisteredTopicSubscribers} topic =
  ListT.toReverseList (STMMultimap.streamByKey topic envRegisteredTopicSubscribers)

type RegisteredOnUnsubscribe m = STMMap.Map SessionID (STMMap.Map Topic (m ()))

registerOnUnsubscribe :: Env m -> SessionID -> Topic -> m () -> STM ()
registerOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID topic eff = do
  mTopics <- STMMap.lookup sID envRegisteredOnUnsubscribe
  topics <- case mTopics of
    Nothing -> do
      x <- STMMap.new
      STMMap.insert x sID envRegisteredOnUnsubscribe
      pure x
    Just x -> pure x
  STMMap.insert eff topic topics

callOnUnsubscribe :: MonadIO m => Env m -> SessionID -> Topic -> m ()
callOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID topic = do
  mEff <- liftIO $ atomically $ do
    mTopics <- STMMap.lookup sID envRegisteredOnUnsubscribe
    case mTopics of
      Nothing -> pure Nothing
      Just topics -> do
        x <- STMMap.lookup topic topics
        STMMap.delete topic topics
        pure x
  case mEff of
    Nothing -> pure ()
    Just eff -> eff

callAllOnUnsubscribe :: MonadIO m => Env m -> SessionID -> m ()
callAllOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID = do
  effs <- liftIO $ atomically $ do
    mTopics <- STMMap.lookup sID envRegisteredOnUnsubscribe
    STMMap.delete sID envRegisteredOnUnsubscribe
    case mTopics of
      Nothing -> pure []
      Just topics -> do
        effs <- fmap snd <$> ListT.toReverseList (STMMap.stream topics)
        STMMap.deleteAll topics
        pure effs
  sequenceA_ effs

type RegisteredOnOpenThreads = STMMap.Map SessionID (STMMap.Map Topic (Async ()))

registerOnOpenThread :: Env m -> SessionID -> Topic -> Async () -> STM ()
registerOnOpenThread Env{envRegisteredOnOpenThreads} sID topic thread = do
  mTopics <- STMMap.lookup sID envRegisteredOnOpenThreads
  topics <- case mTopics of
    Nothing -> do
      x <- STMMap.new
      STMMap.insert x sID envRegisteredOnOpenThreads
      pure x
    Just x -> pure x
  STMMap.insert thread topic topics

killOnOpenThread :: MonadIO m => Env m -> SessionID -> Topic -> m ()
killOnOpenThread Env{envRegisteredOnOpenThreads} sID topic =
  liftIO $ do
    mThread <- atomically $ do
      mTopics <- STMMap.lookup sID envRegisteredOnOpenThreads
      case mTopics of
        Nothing -> pure Nothing
        Just topics -> do
          x <- STMMap.lookup topic topics
          STMMap.delete topic topics
          pure x
    case mThread of
      Nothing -> pure ()
      Just thread -> cancel thread


killAllOnOpenThreads :: MonadIO m => Env m -> SessionID -> m ()
killAllOnOpenThreads Env{envRegisteredOnOpenThreads} sID =
  liftIO $ do
    threads <- atomically $ do
      mTopics <- STMMap.lookup sID envRegisteredOnOpenThreads
      STMMap.delete sID envRegisteredOnOpenThreads
      case mTopics of
        Nothing -> pure []
        Just topics -> do
          x <- fmap snd <$> ListT.toReverseList (STMMap.stream topics)
          STMMap.deleteAll topics
          pure x
    forM_ threads cancel


data Env m = Env
  { envSessionsOutgoing            :: SessionsOutgoing
  , envRegisteredReceive           :: RegisteredReceive m
  , envRegisteredTopicInvalidators :: RegisteredTopicInvalidators
  , envRegisteredTopicSubscribers  :: RegisteredTopicSubscribers
  , envRegisteredOnUnsubscribe     :: RegisteredOnUnsubscribe m
  , envRegisteredOnOpenThreads     :: RegisteredOnOpenThreads
  }


unsafeBroadcastTopic :: MonadIO m => Env m -> Topic -> Value -> m ()
unsafeBroadcastTopic (Env sessions _ _ subs _ _) t v =
  liftIO $ atomically $ do
    ss <- ListT.toReverseList (STMMultimap.streamByKey t subs)
    forM_ ss (\sessionID -> TMapChan.insert sessions sessionID v)


broadcaster :: MonadIO m => Env m -> Broadcast m
broadcaster env = \topic -> do
  mInvalidator <- liftIO $ atomically $ getValidator env topic
  case mInvalidator of
    Nothing -> pure Nothing
    Just invalidator -> pure $ Just $ \v -> case invalidator v of
      Just _ -> Nothing -- is invalid
      Nothing -> Just (unsafeBroadcastTopic env topic v)


-- | Monoid for WriterT (as StateT)
type Paper http = RootedPredTrie Text http


newtype SparrowServerT http m a = SparrowServerT
  { runSparrowServerT :: ReaderT (Env m) (StateT (Paper http) m) a
  } deriving (Functor, Applicative, Monad, MonadIO)

instance MonadTrans (SparrowServerT http) where
  lift x = SparrowServerT (lift (lift x))


execSparrowServerT :: MonadIO m
                   => SparrowServerT http m a
                   -> m (Paper http, Env m)
execSparrowServerT x = do
  env <- liftIO $  Env
               <$> atomically newTMapChan
               <*> STMMap.newIO
               <*> STMMap.newIO
               <*> STMMultimap.newIO
               <*> STMMap.newIO
               <*> STMMap.newIO
  (,env) <$> execSparrowServerT' env x

execSparrowServerT' :: Monad m
                    => Env m
                    -> SparrowServerT http m a
                    -> m (Paper http)
execSparrowServerT' env (SparrowServerT x) = do
  execStateT (runReaderT x env) mempty


tell' :: Monad m => Paper http -> SparrowServerT http m ()
tell' x = SparrowServerT (lift (modify' (<> x)))

ask' :: Monad m => SparrowServerT http m (Env m)
ask' = SparrowServerT ask
