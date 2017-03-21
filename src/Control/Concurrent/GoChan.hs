{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeFamilies              #-}

-- | This module provides bounded channels similar to those seen in the Go
-- programming language.
module Control.Concurrent.GoChan
  ( -- * Types
   Chan
  ,Result(..)
  ,Case(..)
    -- * Functions
  ,chanMake
  ,chanClose
  ,chanRecv
  ,chanTryRecv
  ,chanSend
  ,chanTrySend
  ,chanSelect)
  where

import           Control.Concurrent.MVar
import           Control.Monad
import           Control.Monad.Primitive     (RealWorld)
import           Data.Array.IO
import           Data.IORef
import           Data.List                   (intercalate)
import           Data.Maybe                  (fromJust, isJust, isNothing)
import qualified Data.Vector                 as V
import qualified Data.Vector.Algorithms.Heap as VAH
import qualified Data.Vector.Generic         as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Mutable         as VM
import           Data.Word
import           GHC.Prim                    (Any)
import           System.IO.Unsafe
import           System.Random
import           Unsafe.Coerce

-- | The core data type. A @'Chan' α@ provides a conduit through which messages
-- of type @α@ can be sent and received.
data Chan a = Chan
    { _qcount :: {-# UNPACK #-} !(IORef Int)
    , _qsize  :: {-# UNPACK #-} !Int
    , _buf    :: {-# UNPACK #-} !(IOArray Int a)
    , _sendx  :: {-# UNPACK #-} !(IORef Int)
    , _recvx  :: {-# UNPACK #-} !(IORef Int)
    , _sendq  :: {-# UNPACK #-} !SuspQ
    , _recvq  :: {-# UNPACK #-} !SuspQ
    , _lock   :: {-# UNPACK #-} !(MVar ())
    , _closed :: {-# UNPACK #-} !(IORef Bool)
    , _id     :: {-# UNPACK #-} !Word64
    }

data SuspQ = SuspQ
    { _first :: {-# UNPACK #-} !(IORef (Maybe SomeSuspend))
    , _last  :: {-# UNPACK #-} !(IORef (Maybe SomeSuspend))
    }

data SomeSuspend =
    forall a. SomeSuspend (Suspend a)

data Suspend a = forall b. Suspend
    { _selectDone :: !(Maybe (IORef Bool))
    , _case       :: !(Maybe (Case b))
    , _next       :: !(IORef (Maybe SomeSuspend))
    , _prev       :: !(IORef (Maybe SomeSuspend))
    , _elem       :: !(Maybe (IORef a))
    , _chan       :: !(Chan a)
    , _park       :: !(MVar (Maybe (Suspend a))) -- park, and when unparked, the awoken sleeper is given
    , _sid        :: !Word64
    }

-- | The `Result` record represents the result of waiting to recieve a message
-- on a given channel.
data Result a
    = Msg a
    | Closed

-- | When used with 'chanSelect`, a @'Case' α@ provides a means of waiting for a
-- 'Send' or 'Recv' to complete on a given channel, subsequently invoking the
-- given callback.
--
-- [@'Recv' (chan :: 'Chan' β) (act :: Result β -> IO α)@] Wait to receive a
-- @msg@ on @chan@, invoking @act result@ when selected.
--
-- [@'Send' (chan :: 'Chan' β) (msg :: β) (act :: IO α)@] Wait to send @msg@ on
-- @chan@, invoking @act@ when selected.
data Case a
    = forall b. Recv (Chan b)
                     (Result b -> IO a)
    | forall b. Send (Chan b)
                     b
                     (IO a)

{-# INLINE caseChanId #-}

caseChanId :: Case a -> Word64
caseChanId (Recv chan _) = _id chan
caseChanId (Send chan _ _) = _id chan

{-# NOINLINE currIdRef #-}

currIdRef :: IORef Word64
currIdRef = unsafePerformIO (newIORef 0)

{-# NOINLINE currSIdRef #-}

currSIdRef :: IORef Word64
currSIdRef = unsafePerformIO (newIORef 0)

shuffleVector
    :: (VGM.MVector v e)
    => v RealWorld e -> IO ()
shuffleVector !xs = do
    let !size = VGM.length xs
    forM_ [1 .. size - 1] $
        \i -> do
            j <- randomRIO (0, i)
            vi <- VGM.read xs i
            vj <- VGM.read xs j
            VGM.write xs j vi
            VGM.write xs i vj

-- | When no default action is given, blocks until one of the cases can run,
-- then it executes that case. It chooses one at random if multiple are ready.
--
-- If given a default action, and no cases can run, immediately executes the
-- default action.
chanSelect
    :: [Case a]     -- ^ The list of cases.
    -> Maybe (IO a) -- ^ When 'Nothing', wait synchronously to select a
                    -- case; when @'Just' act@, run @act@ as a default
                    -- instead of blocking.
    -> IO a         -- ^ The value resulting from the selected 'Case'
                    -- (or default action, if given).
chanSelect cases mdefault = do
    -- randomize the poll order to enforce fairness.
    !pollOrder <-
        -- for reasons unknown to me, we get better performance when we don't
        -- explicitly lift out the common fromList expression.
        do vec <- V.thaw (V.fromList cases)
           shuffleVector vec
           V.unsafeFreeze vec
    let !ncases = VG.length pollOrder
    -- we need to aquire locks in a consistent order so we don't deadlock.
    !lockOrder <-
        do vec <- V.thaw (V.fromList cases)
           VAH.sortBy
               (\cas1 cas2 ->
                     caseChanId cas1 `compare` caseChanId cas2)
               vec
           V.unsafeFreeze vec
    selLock lockOrder
    -- PASS 1 - attempt to dequeue a Suspend from one of the channels.
    let pass1 !n = do
            if n /= ncases
                then case pollOrder VG.! n of
                         Recv chan act -> do
                             ms <- dequeue (_sendq chan)
                             case ms of
                                 Just (SomeSuspend s) -> do
                                     elemRef <- newIORef undefined
                                     recv chan (unsafeCoerceSuspend s) (Just elemRef) (selUnlock lockOrder)
                                     val <- readIORef elemRef
                                     act (Msg val)
                                 _ -> do
                                     !qcount <- readIORef (_qcount chan)
                                     if qcount > 0
                                         then do
                                             !recvx <- readIORef (_recvx chan)
                                             val <- readArray (_buf chan) recvx
                                             let !recvx' =
                                                     let !x = recvx + 1
                                                     in if x == _qsize chan
                                                            then 0
                                                            else x
                                             writeIORef (_recvx chan) $! recvx'
                                             writeIORef (_qcount chan) (qcount - 1)
                                             selUnlock lockOrder
                                             act (Msg val)
                                         else do
                                             !isClosed <- readIORef (_closed chan)
                                             if isClosed
                                                 then do
                                                     selUnlock lockOrder
                                                     act Closed
                                                 else do
                                                     pass1 (n + 1)
                         Send chan val act -> do
                             !isClosed <- readIORef (_closed chan)
                             if isClosed
                                 then do
                                     selUnlock lockOrder
                                     fail "send on closed channel"
                                 else do
                                     ms <- dequeue (_recvq chan)
                                     case ms of
                                         Just (SomeSuspend s) -> do
                                             send chan (unsafeCoerceSuspend s) val (selUnlock lockOrder)
                                             act
                                         _ -> do
                                             !qcount <- readIORef (_qcount chan)
                                             if qcount < _qsize chan
                                                 then do
                                                     !sendx <- readIORef (_sendx chan)
                                                     writeArray (_buf chan) sendx val
                                                     let !sendx' =
                                                             let !x = sendx + 1
                                                             in if x == _qsize chan
                                                                    then 0
                                                                    else x
                                                     writeIORef (_sendx chan) sendx'
                                                     writeIORef (_qcount chan) (qcount + 1)
                                                     selUnlock lockOrder
                                                     act
                                                 else do
                                                     pass1 (n + 1)
                else case mdefault of
                         Just def -> do
                             selUnlock lockOrder
                             def
                         _ -> do
                             -- PASS 2 - enqueue a Suspend for each case.
                             --
                             -- the shared 'park' MVark is used wake up this
                             -- thread.
                             park <- newEmptyMVar
                             -- the shared 'selectDone' IORef allows the other
                             -- threads to know who won the race to wake us up
                             -- (via CAS).
                             selectDone <- newIORef False
                             ss <-
                                 V.generateM
                                     ncases
                                     (\n -> do
                                          next <- newIORef Nothing
                                          prev <- newIORef Nothing
                                          id <-
                                              atomicModifyIORef'
                                                  currSIdRef
                                                  (\currId ->
                                                        (currId + 1, currId))
                                          case lockOrder V.! n of
                                              cas@(Send chan val _) -> do
                                                  elemRef <- newIORef (unsafeCoerce val)
                                                  let !s =
                                                          SomeSuspend
                                                              (Suspend
                                                                   (Just selectDone)
                                                                   (Just (unsafeCoerceCase cas))
                                                                   next
                                                                   prev
                                                                   (Just elemRef)
                                                                   (unsafeCoerceChan chan)
                                                                   park
                                                                   id)
                                                  enqueue (_sendq chan) s
                                                  return s
                                              cas@(Recv chan _) -> do
                                                  elemRef <- newIORef undefined
                                                  let !s =
                                                          SomeSuspend
                                                              (Suspend
                                                                   (Just selectDone)
                                                                   (Just (unsafeCoerceCase cas))
                                                                   next
                                                                   prev
                                                                   (Just elemRef)
                                                                   (unsafeCoerceChan chan)
                                                                   park
                                                                   id)
                                                  enqueue (_recvq chan) s
                                                  return s)
                             selUnlock lockOrder
                             ms <- takeMVar park
                             selLock lockOrder
                             -- PASS 3 - dequeue each Suspend we enqueued
                             -- earlier.
                             let pass3 !n = do
                                     case ss VG.! n of
                                         someS@(SomeSuspend s) ->
                                             case s of
                                                 (Suspend _ cas _ _ _ _ _ _) ->
                                                     case cas of
                                                         Just (Send _ _ _) -> do
                                                             --
                                                             dequeueSuspend
                                                                 (_sendq (_chan s))
                                                                 someS
                                                         Just (Recv _ _) -> do
                                                             dequeueSuspend (_recvq (_chan s)) someS
                                     when ((n + 1) /= ncases) (pass3 (n + 1))
                             pass3 0
                             case ms of
                                 Just s -> do
                                     case s of
                                         (Suspend _ cas _ _ _ _ _ _) ->
                                             case cas of
                                                 Just (Send chan _ act) -> do
                                                     selUnlock lockOrder
                                                     unsafeCoerceSendAction act
                                                 Just (Recv chan act) -> do
                                                     !val <- readIORef (fromJust (_elem s))
                                                     selUnlock lockOrder
                                                     unsafeCoerceRecvAction act (Msg val)
                                 _ -> do
                                     -- channel closed, restart loop to figure
                                     -- out which one.
                                     pass1
                                         0
    pass1 0

{-# INLINE unsafeCoerceSendAction #-}

unsafeCoerceSendAction :: IO a -> IO b
unsafeCoerceSendAction = unsafeCoerce

{-# INLINE unsafeCoerceRecvAction #-}

unsafeCoerceRecvAction :: (Result b -> IO a) -> (Result d -> IO c)
unsafeCoerceRecvAction = unsafeCoerce

{-# INLINE unsafeCoerceSuspend #-}

unsafeCoerceSuspend :: Suspend a -> Suspend b
unsafeCoerceSuspend = unsafeCoerce

{-# INLINE unsafeCoerceChan #-}

unsafeCoerceChan :: Chan a -> Chan b
unsafeCoerceChan = unsafeCoerce

{-# INLINE unsafeCoerceCase #-}

unsafeCoerceCase :: Case a -> Case b
unsafeCoerceCase = unsafeCoerce

{-# INLINE lockCase #-}

lockCase :: Case a -> IO ()
lockCase (Recv chan _) = takeMVar (_lock chan)
lockCase (Send chan _ _) = takeMVar (_lock chan)

{-# INLINE unlockCase #-}

unlockCase :: Case a -> IO ()
unlockCase (Recv chan _) = putMVar (_lock chan) ()
unlockCase (Send chan _ _) = putMVar (_lock chan) ()

selLock
    :: (VG.Vector v e, e ~ Case a)
    => v (Case a) -> IO ()
selLock !vec = do
    go 0 maxBound
  where
    len = VG.length vec
    go n prevId = do
        let !cas = vec VG.! n
        if n == len - 1
            then do
                lockCase cas
            else do
                when (caseChanId cas /= prevId) $ do lockCase cas
                go (n + 1) (caseChanId cas)

selUnlock
    :: (VG.Vector v e, e ~ Case a)
    => v (Case a) -> IO ()
selUnlock !vec = do
    go (len - 1) maxBound
  where
    len = VG.length vec
    go n prevId = do
        let !cas = vec VG.! n
        if n == 0
            then do
                unlockCase cas
            else do
                when (caseChanId cas /= prevId) $ do (unlockCase cas)
                go (n - 1) (caseChanId cas)

-- | Make a channel with the given buffer size.
chanMake
    :: Int -> IO (Chan a)
chanMake !size = do
    ary <- newArray_ (0, size - 1)
    qcount <- newIORef 0
    sendx <- newIORef 0
    recvx <- newIORef 0
    sendq_first <- newIORef Nothing
    sendq_last <- newIORef Nothing
    recvq_first <- newIORef Nothing
    recvq_last <- newIORef Nothing
    lock <- newMVar ()
    closed <- newIORef False
    id <-
        atomicModifyIORef'
            currIdRef
            (\currId ->
                  (currId + 1, currId))
    return
        Chan
        { _qcount = qcount
        , _qsize = size
        , _buf = ary
        , _sendx = sendx
        , _recvx = recvx
        , _sendq = SuspQ sendq_first sendq_last
        , _recvq = SuspQ recvq_first recvq_last
        , _lock = lock
        , _closed = closed
        , _id = id
        }

-- | Wait to successfully send a message on a channel.
--
-- Throws an exception when sending on a closed channel.
chanSend
    :: Chan a -> a -> IO ()
chanSend !chan !val = void $ chanSendInternal chan val True

-- | Attempt to send a message on a channel. The message will be sent iff the
-- channel has spare space in its buffer or another thread is waiting to recieve
-- a message on this channel.
--
-- Returns 'True' iff the message was sent.
--
-- Throws an exception when sending on a closed channel.
chanTrySend
    :: Chan a -> a -> IO Bool
chanTrySend !chan !val = chanSendInternal chan val False

-- returns True if a message was sent; otherwise returns False
chanSendInternal :: Chan a -> a -> Bool -> IO Bool
chanSendInternal !chan !val !block = do
    !isClosed <- readIORef (_closed chan)
    !recvq_first <- readIORef (_first (_recvq chan))
    !qcount <- readIORef (_qcount chan)
    -- Fast path: check for failed non-blocking operation without acquiring the lock.
    if not block && not isClosed && ((_qsize chan == 0 && isJust recvq_first) || (_qsize chan > 0 && qcount == _qsize chan))
        then return False
        else do
            takeMVar (_lock chan)
            !isClosed <- readIORef (_closed chan)
            if isClosed
                then do
                    putMVar (_lock chan) ()
                    fail "send on closed channel"
                else do
                    ms <- dequeue (_recvq chan)
                    case ms of
                        Just (SomeSuspend s) -> do
                            send chan (unsafeCoerceSuspend s) val (putMVar (_lock chan) ())
                            return True
                        Nothing -> do
                            !qcount <- readIORef (_qcount chan)
                            if qcount < _qsize chan
                                then do
                                    !sendx <- readIORef (_sendx chan)
                                    writeArray (_buf chan) sendx val
                                    writeIORef (_sendx chan) $! (sendx + 1)
                                    let !sendx' = sendx + 1
                                    if sendx' == _qsize chan
                                        then writeIORef (_sendx chan) 0
                                        else writeIORef (_sendx chan) $! sendx'
                                    writeIORef (_qcount chan) (qcount + 1)
                                    putMVar (_lock chan) ()
                                    return True
                                else if not block
                                         then do
                                             putMVar (_lock chan) ()
                                             return False
                                         else do
                                             next <- newIORef Nothing
                                             prev <- newIORef Nothing
                                             elem <- newIORef val
                                             park <- newEmptyMVar -- we're about to park
                                             id <-
                                                 atomicModifyIORef'
                                                     currSIdRef
                                                     (\currId ->
                                                           (currId + 1, currId))
                                             let !s = (SomeSuspend (Suspend Nothing Nothing next prev (Just elem) chan park id))
                                             enqueue (_sendq chan) s
                                             putMVar (_lock chan) ()
                                             ms' <- takeMVar park
                                             case ms' of
                                                 Nothing -> do
                                                     !isClosed <- readIORef (_closed chan)
                                                     unless isClosed (fail "chansend: spurious wakeup")
                                                     fail "send on closed channel"
                                                 _ -> return True

send :: Chan a -> Suspend a -> a -> IO () -> IO ()
send !chan !s !val !unlock = do
    case _elem s of
        Just elemRef -> do
            writeIORef elemRef val
        _ -> do
            return ()
    unlock
    putMVar (_park s) (Just s) -- unpark

-- | Close a channel.
chanClose
    :: Chan a -> IO ()
chanClose !chan = do
    takeMVar (_lock chan)
    !isClosed <- readIORef (_closed chan)
    when isClosed $
        do putMVar (_lock chan) ()
           fail "close of closed channel"
    writeIORef (_closed chan) True
    ss <- releaseReaders [] chan
    ss <- releaseWriters ss chan
    putMVar (_lock chan) ()
    wakeSuspends ss
  where
    releaseReaders ss chan = do
        ms <- dequeue (_recvq chan)
        case ms of
            Nothing -> return ss
            Just s -> releaseReaders (s : ss) chan
    releaseWriters ss chan = do
        ms <- dequeue (_sendq chan)
        case ms of
            Nothing -> return ss
            Just s -> releaseReaders (s : ss) chan
    wakeSuspends ss =
        forM_
            ss
            (\(SomeSuspend s) ->
                  putMVar (_park s) Nothing)

-- data type used internally to represent the result of waiting on a channel
data RecvResult
    = RecvWouldBlock
    | RecvGotMessage
    | RecvClosed

-- | Attempt to receive a message on a channel. A message will be recieved iff
-- the channel has a message in its buffer or another thread is waiting to
-- send a message on this channel.
chanTryRecv
    :: Chan a -> IO (Maybe (Result a))
chanTryRecv !chan = do
    ref <- newIORef undefined
    chanRecvInternal chan (Just ref) False >>=
        \case
            RecvWouldBlock -> return Nothing
            RecvClosed -> return (Just Closed)
            RecvGotMessage-> Just <$> Msg <$> readIORef ref

-- | Wait to receive a message on a channel.
chanRecv
    :: Chan a -> IO (Result a)
chanRecv !chan = do
    ref <- newIORef undefined
    chanRecvInternal chan (Just ref) True >>=
        \case
            RecvWouldBlock -> fail "the impossible happened"
            RecvClosed -> return Closed
            RecvGotMessage -> Msg <$> readIORef ref

chanRecvInternal :: Chan a -> Maybe (IORef a) -> Bool -> IO RecvResult
chanRecvInternal !chan !melemRef !block = do
    -- Fast path: check for failed non-blocking operation without acquiring the lock.
    -- WARNING: the order of these reads is important.
    !sendq_first <- readIORef (_first (_sendq chan))
    !qcount <- atomicReadIORef (_qcount chan)
    !isClosed <- atomicReadIORef (_closed chan)
    if not block && ((_qsize chan == 0 && isNothing sendq_first) || (_qsize chan > 0 && qcount == _qsize chan)) && not isClosed
        then return RecvWouldBlock
        else do
            takeMVar (_lock chan)
            !isClosed <- readIORef (_closed chan)
            !qcount <- readIORef (_qcount chan)
            if isClosed && qcount == 0
                then do
                    putMVar (_lock chan) ()
                    return RecvClosed
                else do
                    ms <- dequeue (_sendq chan)
                    case ms of
                        Just (SomeSuspend s) -> do
                            recv chan (unsafeCoerceSuspend s) melemRef (putMVar (_lock chan) ())
                            return RecvGotMessage
                        _ ->
                            if qcount > 0
                                then do
                                    !recvx <- readIORef (_recvx chan)
                                    val <- readArray (_buf chan) recvx
                                    case melemRef of
                                        Just elemRef -> writeIORef elemRef val
                                        _ -> return ()
                                    let !recvx' =
                                            let !x = recvx + 1
                                            in if x == _qsize chan
                                                   then 0
                                                   else x
                                    writeIORef (_recvx chan) $! recvx'
                                    modifyIORef' (_qcount chan) (subtract 1)
                                    putMVar (_lock chan) ()
                                    return RecvGotMessage
                                else if not block
                                         then do
                                             putMVar (_lock chan) ()
                                             return RecvWouldBlock
                                         else do
                                             next <- newIORef Nothing
                                             prev <- newIORef Nothing
                                             park <- newEmptyMVar -- we're about to park
                                             id <-
                                                 atomicModifyIORef'
                                                     currSIdRef
                                                     (\currId ->
                                                           (currId + 1, currId))
                                             let !s = SomeSuspend (Suspend Nothing Nothing next prev melemRef chan park id)
                                             enqueue (_recvq chan) s
                                             putMVar (_lock chan) ()
                                             ms' <- takeMVar park -- park
                                             if isJust ms'
                                                then return RecvGotMessage
                                                else return RecvClosed

recv :: Chan a -> Suspend a -> Maybe (IORef a) -> IO () -> IO ()
recv !chan !s !melemRef !unlock = do
    if _qsize chan == 0
        then case melemRef of
                 Just elemRef -> do
                     !val <- readIORef (fromJust (_elem s))
                     writeIORef elemRef val
                 _ -> return ()
        else do
            !recvx <- readIORef (_recvx chan)
            val <- readArray (_buf chan) recvx
            case melemRef of
                Just elemRef -> writeIORef elemRef val
                _ -> return ()
            !val' <- readIORef (fromJust (_elem s))
            writeArray (_buf chan) recvx val'
            let !recvx' =
                    let !x = recvx + 1
                    in if x == _qsize chan
                           then 0
                           else x
            writeIORef (_recvx chan) $! recvx'
            writeIORef (_sendx chan) $! recvx'
    unlock
    putMVar (_park s) (Just s) -- unpark

-- enqueue a Supsend.
enqueue
    :: SuspQ -> SomeSuspend -> IO ()
enqueue !q someS@(SomeSuspend s) = do
    writeIORef (_next s) Nothing
    mx <- readIORef . _last $ q
    case mx of
        Nothing -> do
            writeIORef (_prev s) Nothing
            writeIORef (_first q) (Just someS)
            writeIORef (_last q) (Just someS)
        Just someX@(SomeSuspend x) -> do
            writeIORef (_prev s) (Just someX)
            writeIORef (_next x) (Just someS)
            writeIORef (_last q) (Just someS)

-- dequeue each Suspend until one is found that can be resumed;
-- if we dequeue one that participates in a select, and it is already
-- flagged as selected, continue dequeuing.
dequeue
    :: SuspQ -> IO (Maybe SomeSuspend)
dequeue !q = do
    !ms <- readIORef (_first q)
    case ms of
        Nothing -> return Nothing
        Just someS@(SomeSuspend s) -> do
            !my <- readIORef (_next s)
            case my of
                Nothing -> do
                    writeIORef (_first q) Nothing
                    writeIORef (_last q) Nothing
                Just someY@(SomeSuspend y) -> do
                    writeIORef (_prev y) Nothing
                    writeIORef (_first q) (Just someY)
                    writeIORef (_next s) Nothing
            case _selectDone s of
                Nothing -> return (Just someS)
                Just doneRef -> do
                    done <- readIORef doneRef
                    if not done
                        then do
                            -- attempt to set the "selectdone" flag and return
                            -- the Suspend.
                            -- if someone beat us to it, try dequeuing again.
                            oldDone <-
                                atomicModifyIORef'
                                    doneRef
                                    (\oldDone ->
                                          (True, oldDone))
                            if oldDone
                                then do
                                    -- we did *not* win the race; try again
                                    dequeue q
                                else do
                                    -- we won! done.
                                    return
                                        (Just someS)
                        else do
                            -- we did *not* win the race; try again
                            dequeue q

{-# INLINE atomicReadIORef #-}

atomicReadIORef :: IORef a -> IO a
atomicReadIORef !ref =
    atomicModifyIORef'
        ref
        (\oldVal ->
              (oldVal, oldVal))

-- TODO: Consider (carefully) using pointer equality instead of maintaining a
-- unique ID.
eqSuspend
    :: Suspend a -> Suspend b -> Bool
eqSuspend !s1 !s2 = _sid s1 == _sid s2

dequeueSuspend :: SuspQ -> SomeSuspend -> IO ()
dequeueSuspend !q someS@(SomeSuspend s) = do
    !mx <- readIORef (_prev s)
    !my <- readIORef (_next s)
    case mx of
        Just someX@(SomeSuspend x) ->
            case my of
                Just someY@(SomeSuspend y) -> do
                    writeIORef (_next x) (Just someY)
                    writeIORef (_prev y) (Just someX)
                    writeIORef (_next s) Nothing
                    writeIORef (_prev s) Nothing
                _ -> do
                    writeIORef (_next x) Nothing
                    writeIORef (_last q) (Just someX)
                    writeIORef (_prev s) Nothing
        _ ->
            case my of
                Just someY@(SomeSuspend y) -> do
                    writeIORef (_prev y) Nothing
                    writeIORef (_first q) (Just someY)
                    writeIORef (_next s) Nothing
                _ -> do
                    !mfirst <- readIORef (_first q)
                    case mfirst of
                        Just someFirst@(SomeSuspend first) ->
                            when (first `eqSuspend` s) $
                            do writeIORef (_first q) Nothing
                               writeIORef (_last q) Nothing
                        _ -> return ()

--------------------------------------------------------------------------------
-- misc. debug utils
waitqToList
    :: SuspQ -> IO [SomeSuspend]
waitqToList q = do
    !ms <- readIORef (_first q)
    case ms of
        Just s -> sleeperChain s
        _ -> return []

sleeperChain :: SomeSuspend -> IO [SomeSuspend]
sleeperChain someS@(SomeSuspend s) = do
    !mnext <- readIORef (_next s)
    case mnext of
        Just next -> do
            ss <- sleeperChain next
            return (someS : ss)
        _ -> return [someS]

printSuspQ :: SuspQ -> IO ()
printSuspQ q = do
    ss <- waitqToList q
    let !chain =
            intercalate
                "->"
                (map
                     (\(SomeSuspend s) ->
                           "(SID: " ++ show (_sid s) ++ ", CID: " ++ show (_id (_chan s)) ++ ")")
                     ss)
    putStrLn $ "WAITQ: " ++ chain
