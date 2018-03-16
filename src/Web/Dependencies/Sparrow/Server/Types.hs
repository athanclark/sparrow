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
  , unsafeRegisterReceive
  , sendTo
  , registerOnUnsubscribe
  , registerOnOpenThread
  , registerInvalidator
  , broadcaster
  , getCurrentRegisteredTopics
  , getCallReceive
  , killOnOpenThread
  , killAllOnOpenThreads
  , callOnUnsubscribe
  , callAllOnUnsubscribe
  , unregisterReceive
  , unregisterSession
  , addSubscriber
  , delSubscriber
  , delSubscriberFromAllTopics
  ) where

import Web.Dependencies.Sparrow.Types (Topic (..), Broadcast, WithTopic (..), WSOutgoing (WSOutgoing))
import Web.Dependencies.Sparrow.Session (SessionID)

import Data.Text (Text)
import Data.Trie.Pred.Base (RootedPredTrie)
import Data.Monoid ((<>))
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Foldable (sequenceA_)
import Data.Aeson (FromJSON, Value)
import qualified Data.Aeson as Aeson
import qualified ListT as ListT
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.HashSet (HashSet)
import qualified Data.HashSet as HS
import Control.Monad (forM_, join)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.State (StateT, execStateT, modify')
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans (MonadTrans (lift))
import Control.Concurrent.Async (Async, cancel)
import Control.Concurrent.STM (STM, atomically, TVar, newTVarIO, writeTVar, readTVar, modifyTVar')
import Control.Concurrent.STM.TMapChan.Hash (TMapChan, newTMapChan)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import Control.Concurrent.STM.TMapMVar.Hash (TMapMVar, newTMapMVar)
import qualified Control.Concurrent.STM.TMapMVar.Hash as TMapMVar



type SessionsOutgoing = TMapChan SessionID (WSOutgoing (WithTopic Value))

sendTo :: Env m -> SessionID -> WSOutgoing (WithTopic Value) -> STM ()
sendTo Env{envSessionsOutgoing} sID v =
  TMapChan.insert envSessionsOutgoing sID v


type RegisteredReceive m = -- STMMap.Map SessionID (STMMap.Map Topic (Value -> Maybe (m ())))
  TMapMVar SessionID (TMapMVar Topic (Value -> Maybe (m ())))


-- unsafe because receiver isn't type-caste to the expected Topic
unsafeRegisterReceive :: MonadIO m
                      => Env m -> SessionID -> Topic -> (Value -> Maybe (m ())) -> IO ()
unsafeRegisterReceive env@Env{envRegisteredReceive} sID topic f = do
  mTopics <- TMapMVar.tryObserve envRegisteredReceive sID
  case mTopics of
    Nothing -> do
      topics <- atomically newTMapMVar
      TMapMVar.insertForce topics topic f
      putStrLn $ "No topics, adding.. " ++ show topic
      TMapMVar.insertForce envRegisteredReceive sID topics
      putStrLn "added."
      ks <- getCurrentRegisteredTopics env sID
      putStrLn $ "Topics...: " ++ show ks
    Just topics -> do
      TMapMVar.insertForce topics topic f


unregisterReceive :: Env m -> SessionID -> Topic -> IO ()
unregisterReceive Env{envRegisteredReceive} sID topic = do
  putStrLn $ "Unregistering: " ++ show sID ++ ", " ++ show topic
  mTopics <- TMapMVar.tryObserve envRegisteredReceive sID
  case mTopics of
    Nothing -> pure ()
    Just topics -> TMapMVar.delete topics topic

unregisterSession :: Env m -> SessionID -> IO ()
unregisterSession Env{envRegisteredReceive} sID = do
  putStrLn $ "Unregistering session: " ++ show sID
  TMapMVar.delete envRegisteredReceive sID


getCallReceive :: MonadIO m
               => Env m -> SessionID -> Topic -> Value -> IO (Maybe (m ()))
getCallReceive Env{envRegisteredReceive} sID topic v = do
  putStrLn $ "Looking up session " ++ show sID
  topics <- TMapMVar.observe envRegisteredReceive sID
  putStrLn $ "Looking up topic " ++ show topic
  onReceive <- TMapMVar.observe topics topic
  putStrLn "Got onReceive"
  pure (onReceive v)

getCurrentRegisteredTopics :: Env m -> SessionID -> IO [Topic]
getCurrentRegisteredTopics Env{envRegisteredReceive} sID = do
  mTopics <- TMapMVar.tryObserve envRegisteredReceive sID
  case mTopics of
    Nothing -> do
      putStrLn "Ain't got dick?"
      -- topics <- atomically newTMapMVar
      -- TMapMVar.insertForce envRegisteredReceive sID topics
      pure []
    Just topics -> atomically $ TMapMVar.keys topics

type RegisteredTopicInvalidators = TVar (HashMap Topic (Value -> Maybe String))

registerInvalidator :: forall deltaIn m
                     . FromJSON deltaIn
                    => Env m -> Topic -> Proxy deltaIn -> STM ()
registerInvalidator Env{envRegisteredTopicInvalidators} topic Proxy =
  let go v = case Aeson.fromJSON v of
              Aeson.Error e -> Just e
              Aeson.Success (_ :: deltaIn) -> Nothing
  in  modifyTVar' envRegisteredTopicInvalidators (HM.insert topic go)

getValidator :: Env m -> Topic -> STM (Maybe (Value -> Maybe String))
getValidator Env{envRegisteredTopicInvalidators} topic =
  HM.lookup topic <$> readTVar envRegisteredTopicInvalidators

type RegisteredTopicSubscribers = TVar (HashMap Topic (HashSet SessionID))

addSubscriber :: Env m -> Topic -> SessionID -> STM ()
addSubscriber Env{envRegisteredTopicSubscribers} topic sID =
  modifyTVar' envRegisteredTopicSubscribers
    (HM.alter (maybe (Just (HS.singleton sID)) (Just . HS.insert sID)) topic)

delSubscriber :: Env m -> Topic -> SessionID -> STM ()
delSubscriber Env{envRegisteredTopicSubscribers} topic sID =
  let go xs
        | xs == HS.singleton sID = Nothing
        | otherwise = Just (HS.delete sID xs)
  in  modifyTVar' envRegisteredTopicSubscribers
        (HM.alter (maybe Nothing go) topic)

delSubscriberFromAllTopics :: Env m -> SessionID -> STM ()
delSubscriberFromAllTopics env@Env{envRegisteredTopicSubscribers} sID = do
  allTopics <- HM.keys <$> readTVar envRegisteredTopicSubscribers
  forM_ allTopics (\topic -> delSubscriber env topic sID)

getSubscribers :: Env m -> Topic -> STM [SessionID]
getSubscribers Env{envRegisteredTopicSubscribers} topic =
  maybe [] HS.toList . HM.lookup topic <$> readTVar envRegisteredTopicSubscribers

type RegisteredOnUnsubscribe m = TVar (HashMap SessionID (HashMap Topic (m ())))

registerOnUnsubscribe :: Env m -> SessionID -> Topic -> m () -> STM ()
registerOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID topic eff = do
  xs <- readTVar envRegisteredOnUnsubscribe
  let topics = fromMaybe HM.empty (HM.lookup sID xs)
  modifyTVar' envRegisteredOnUnsubscribe (HM.insert sID (HM.insert topic eff topics))

callOnUnsubscribe :: MonadIO m => Env m -> SessionID -> Topic -> m ()
callOnUnsubscribe Env{envRegisteredOnUnsubscribe} sID topic = do
  mEff <- liftIO $ atomically $ do
    xs <- readTVar envRegisteredOnUnsubscribe
    case HM.lookup sID xs of
      Nothing -> pure Nothing
      Just topics -> do
        let x = HM.lookup topic topics
        modifyTVar' envRegisteredOnUnsubscribe (HM.adjust (HM.delete topic) sID)
        pure x
  case mEff of
    Nothing -> pure ()
    Just eff -> eff

callAllOnUnsubscribe :: MonadIO m => Env m -> SessionID -> m ()
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

type RegisteredOnOpenThreads =
  TVar (HashMap SessionID (HashMap Topic (Async ())))

registerOnOpenThread :: Env m -> SessionID -> Topic -> Async () -> STM ()
registerOnOpenThread Env{envRegisteredOnOpenThreads} sID topic thread = do
  xs <- readTVar envRegisteredOnOpenThreads
  let topics = fromMaybe HM.empty (HM.lookup sID xs)
  modifyTVar' envRegisteredOnOpenThreads
    (HM.insert sID (HM.insert topic thread topics))

killOnOpenThread :: MonadIO m => Env m -> SessionID -> Topic -> IO ()
killOnOpenThread Env{envRegisteredOnOpenThreads} sID topic = do
  mThread <- atomically $ do
    xs <- readTVar envRegisteredOnOpenThreads
    case HM.lookup sID xs of
      Nothing -> pure Nothing
      Just topics -> do
        let x = HM.lookup topic topics
        modifyTVar' envRegisteredOnOpenThreads (HM.adjust (HM.delete topic) sID)
        pure x
  case mThread of
    Nothing -> pure ()
    Just thread -> cancel thread


killAllOnOpenThreads :: MonadIO m => Env m -> SessionID -> IO ()
killAllOnOpenThreads Env{envRegisteredOnOpenThreads} sID = do
  threads <- atomically $ do
    xs <- readTVar envRegisteredOnOpenThreads
    case HM.lookup sID xs of
      Nothing -> pure []
      Just topics -> do
        let x = HM.elems topics
        modifyTVar' envRegisteredOnOpenThreads (HM.delete sID)
        pure x
  forM_ threads cancel


data Env m = Env
  { envSessionsOutgoing            :: {-# UNPACK #-} !SessionsOutgoing
  , envRegisteredReceive           :: {-# UNPACK #-} !(RegisteredReceive m)
  , envRegisteredTopicInvalidators :: {-# UNPACK #-} !RegisteredTopicInvalidators
  , envRegisteredTopicSubscribers  :: {-# UNPACK #-} !RegisteredTopicSubscribers
  , envRegisteredOnUnsubscribe     :: {-# UNPACK #-} !(RegisteredOnUnsubscribe m)
  , envRegisteredOnOpenThreads     :: {-# UNPACK #-} !RegisteredOnOpenThreads
  }


unsafeBroadcastTopic :: MonadIO m => Env m -> Topic -> Value -> m ()
unsafeBroadcastTopic env t v =
  liftIO $ atomically $ do
    ss <- getSubscribers env t
    forM_ ss (\sessionID -> sendTo env sessionID (WSOutgoing (WithTopic t v)))


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
               <*> atomically newTMapMVar
               <*> newTVarIO HM.empty
               <*> newTVarIO HM.empty
               <*> newTVarIO HM.empty
               <*> newTVarIO HM.empty
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
