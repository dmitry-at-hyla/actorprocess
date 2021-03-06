module Control.Process.Process where

import Control.Process.Delay
import Control.Process.Action

import Control.Monad (when)
import Control.Monad.State
import Control.Monad.Trans
import Control.Concurrent
import Data.Function (on)
import Data.Maybe (isJust)
import GHC.Conc
import System.IO.Error(try)
import Control.Exception(finally)


data Process ch = Process { thread :: ThreadId,  channel :: Chan ch }

instance Show (Process a) where
    show (Process th _) = "Process " ++ show th

instance Eq (Process a) where
    (==) = (==) `on` thread

instance Ord (Process a) where
    compare = compare `on` thread

newtype Proc ch val
    = Proc {fromProc :: StateT (Chan ch) IO val}
        deriving (Monad, MonadIO, MonadState (Chan ch))

myChannel :: Proc ch (Chan ch)
myChannel = get

instance Action (Proc msg) where
    action proc = evalStateT (fromProc proc) =<< newChan

actionWith :: Proc msg val -> Chan msg -> IO val
actionWith = evalStateT . fromProc

withChannel :: Chan msg -> Proc msg val -> Proc t val
withChannel ch proc = liftIO $ actionWith proc ch

valProc :: Proc a val -> Proc b val
valProc proc = do
    ch <- liftIO newChan
    withChannel ch proc

-- Start new process
spawnWith, spawnOSWith -- With channel
    :: Proc remoteMsg () -> Chan remoteMsg -> Proc msg (Process remoteMsg)
spawnWith proc ch = do
    th <- liftIO $ forkIO $ actionWith proc ch
    return $ Process th ch
spawnOSWith proc ch = do
    th <- liftIO $ forkOS $ actionWith proc ch
    return $ Process th ch

spawn, spawnOS -- With new channel
    :: Proc remoteMsg () -> Proc msg (Process remoteMsg)
spawn proc = spawnWith proc =<< liftIO newChan
spawnOS proc = spawnOSWith proc =<< liftIO newChan

spawnMy, spawnOSMy, -- With channel of current process
    spawnDup, spawnOSDup -- With duplicated channel of current process
        :: Proc msg () -> Proc msg (Process msg)
spawnMy proc = spawnWith proc =<< get
spawnOSMy proc = spawnOSWith proc =<< get
spawnDup proc = spawnWith proc =<< liftIO . dupChan =<< get
spawnOSDup proc = spawnOSWith proc =<< liftIO . dupChan =<< get

-- Thread Status
status :: Process a -> Proc b ThreadStatus
status (Process th _) = liftIO $ threadStatus th

-- wait of completion
waitProcess :: Process a -> Proc b ThreadStatus
waitProcess proc = do
    st <- status proc
    case st of
        ThreadRunning -> waitProcess proc
        ThreadBlocked _ -> waitProcess proc
        st -> return st

waitProcess_ :: Process a -> Proc b ()
waitProcess_ proc = waitProcess proc >> return ()

-- Kill process
kill :: Process remoteMsg -> Proc msg ()
kill (Process th _) = liftIO $ killThread th

-- Gep process link
self :: Proc msg (Process msg)
self = do
    th <- liftIO myThreadId
    return . Process th =<< get

-- Delay
delay :: Integer -> Proc msg ()
delay = liftIO . threadDelayInteger


-- Sending 
send, sendBack :: Process remoteMsg -> remoteMsg -> Proc msg ()
send (Process _ ch) = liftIO . writeChan ch
sendBack (Process _ ch) = liftIO . unGetChan ch

sendMe, sendMeBack :: msg -> Proc msg ()
sendMe msg = do
    Process _ ch <- self
    liftIO $ writeChan ch msg
sendMeBack msg = do
    Process _ ch <- self
    liftIO $ unGetChan ch msg

-- Sending from IO monad
sendIO, sendBackIO :: Process msg -> msg -> IO ()
sendIO proc = action . send proc
sendBackIO proc = action . sendBack proc

recv :: Proc msg msg
recv = liftIO . readChan =<< get

recvDelay :: Integer -> Proc msg (Maybe msg)
recvDelay n = get >>= liftIO . readChanDelay n

recvMaybe :: Proc msg (Maybe msg)
recvMaybe = liftIO . readChanNow =<< get

-- clear channel
chanClear :: Proc msg ()
chanClear = do
    msg <- recvMaybe
    when (isJust msg) chanClear

isEmpty :: Proc msg Bool
isEmpty = liftIO . isEmptyChan =<< get

-- try & finally 
tryProc :: Proc t a -> Proc t (Either IOError a)
tryProc proc = get >>= liftIO . try . actionWith proc

finallyProc :: Proc t a -> Proc t b -> Proc t a
finallyProc first afterward = do
    ch <- get
    liftIO $ finally (actionWith first ch) $ actionWith afterward ch

