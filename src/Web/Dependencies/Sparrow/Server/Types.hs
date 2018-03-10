module Web.Dependencies.Sparrow.Server.Types
  ( Tries (..)
  , SparrowServerT
  , execSparrowServerT
  ) where

import Data.Text (Text)
import Data.Trie.Pred.Base (RootedPredTrie)
import Data.Monoid ((<>))
import Control.Monad.State (StateT, execStateT, modify')


data Tries http websocket = Tries
  { trieHttp      :: RootedPredTrie Text http
  , trieWebSocket :: RootedPredTrie Text websocket
  }

instance Monoid (Tries http websocket) where
  mempty = Tries mempty mempty
  mappend (Tries http1 ws1) (Tries http2 ws2) = Tries (http1 <> http2) (ws1 <> ws2)

newtype SparrowServerT http websocket m a = SparrowServerT
  { runSparrowServerT :: StateT (Tries http websocket) m a
  }

execSparrowServerT :: Monad m => SparrowServerT http websocket m a -> m (Tries http websocket)
execSparrowServerT (SparrowServerT x) = execStateT x mempty


tell' :: Monad m => Tries http websocket -> SparrowServerT http websocket m ()
tell' x = SparrowServerT (modify' (<> x))
