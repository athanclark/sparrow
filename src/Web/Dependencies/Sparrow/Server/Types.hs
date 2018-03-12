{-# LANGUAGE
    GeneralizedNewtypeDeriving
  , DeriveFunctor
  , TupleSections
  #-}

module Web.Dependencies.Sparrow.Server.Types
  ( SparrowServerT
  , execSparrowServerT
  , execSparrowServerT'
  , tell'
  , ask'
  , unsafeBroadcastTopic
  ) where

import Web.Dependencies.Sparrow.Types (Topic (..))
import Web.Dependencies.Sparrow.Session (SessionID)

import Data.Text (Text)
import Data.Trie.Pred.Base (RootedPredTrie)
import Data.Monoid ((<>))
import Data.Aeson (Value)
import qualified ListT as ListT
import Control.Monad (forM_)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.State (StateT, execStateT, modify')
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans (MonadTrans (lift))
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMapChan.Hash (TMapChan, newTMapChan)
import qualified Control.Concurrent.STM.TMapChan.Hash as TMapChan
import qualified STMContainers.Map as STMMap
import qualified STMContainers.Multimap as STMMultimap



type SessionsOutgoing = TMapChan SessionID Value

type RegisteredReceive m = STMMap.Map SessionID (STMMap.Map Topic (Value -> Maybe (m ())))

type RegisteredTopicInvalidators = STMMap.Map Topic (Value -> Maybe String)

type RegisteredTopicSubscribers = STMMultimap.Multimap Topic SessionID


type Env m =
  ( SessionsOutgoing
  , RegisteredReceive m
  , RegisteredTopicInvalidators
  , RegisteredTopicSubscribers
  )


unsafeBroadcastTopic :: MonadIO m => Env m -> Topic -> Value -> m ()
unsafeBroadcastTopic (sessions,_,_,subs) t v =
  liftIO $ atomically $ do
    ss <- ListT.toReverseList (STMMultimap.streamByKey t subs)
    forM_ ss (\sessionID -> TMapChan.insert sessions sessionID v)


-- | Monoid for WriterT (as StateT)
type Paper http = RootedPredTrie Text http


newtype SparrowServerT http m a = SparrowServerT
  { runSparrowServerT :: ReaderT (Env m) (StateT (Paper http) m) a
  } deriving (Functor, Applicative, Monad, MonadIO)

execSparrowServerT :: MonadIO m
                   => SparrowServerT http m a
                   -> m (Paper http, Env m)
execSparrowServerT x = do
  env <- liftIO $ (,,,) <$> atomically newTMapChan <*> STMMap.newIO <*> STMMap.newIO <*> STMMultimap.newIO
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
