module Web.Dependencies.Sparrow.Types where

import Data.Text (Text)
import Data.Aeson (Value)


data ServerArgs m deltaOut = ServerArgs
  { serverSendCurrent   :: deltaOut -> m ()
  , serverSendBroadcast :: [Text] -> m (Maybe (Value -> Maybe (m ())))
  }

data ServerInitArgs m = ServerInitArgs
  { serverInitReject :: m ()
  , serverInitAccept :: m ()
  }

data ServerDeltaInArgs m = ServerDeltaInArgs
  { serverDeltaReject :: m ()
  }

data ServerReturn m initIn initOut deltaIn = ServerReturn
  { serverReceive       :: ServerDeltaInArgs m -> deltaIn -> m ()
  , serverInit          :: ServerInitArgs m -> initIn -> m initOut
  , serverOnUnsubscribe :: m ()
  }

newtype Server m initIn initOut deltaIn deltaOut = Server
  { getServer :: ServerArgs m deltaOut -> ServerReturn m initIn initOut deltaIn
  }



data ClientArgs m initIn initOut deltaIn = ClientArgs
  { clientInit          :: initIn -> m initOut
  , clientSendCurrent   :: deltaIn -> m ()
  , clientSendBroadcast :: [Text] -> m (Maybe (Value -> Maybe (m ())))
  }

data ClientDeltaOutArgs m = ClientDeltaOutArgs
  { clientUnsubscribe :: m ()
  }

data ClientReturn m deltaOut = ClientReturn
  { clientReceive  :: ClientDeltaOutArgs m -> deltaOut -> m ()
  , clientOnReject :: m ()
  }

newtype Client m initIn initOut deltaIn deltaOut = Client
  { getClient :: ClientArgs m initIn initOut deltaIn -> m (ClientReturn m deltaOut)
  }
