module Pipes.Unagi where

import Pipes (Producer, Consumer, (>->), yield, await, runEffect)
import Control.Concurrent.Chan.Unagi (InChan, OutChan, newChan, readChan, writeChan)
import Control.Monad (forever, void)
import Control.Concurrent.MonadIO (MonadIO, HasFork, liftIO, fork, threadDelay, forkIO)
import Control.Monad.Trans.Class (lift)
import qualified Pipes.Prelude as P

producer :: (MonadIO m) => OutChan a -> Producer a m r
producer outChan = forever $ do
  msg <- liftIO $ readChan outChan
  yield msg
  -- TODO: catch BlockedIndefinitelyOnMVar and close producer properly
  -- If I can use async, I can instead poll a1 and a2 and if they are both complete
  -- I will return a tuple of their values. This should then close as soon as p1 and
  -- p2 are both closed and no BlockedIndefinitelyOnMVar will be thrown

combine :: (MonadIO m, HasFork m) => Producer a m r -> Producer a m r -> Producer a m r
combine p1 p2 = do
  (inChan, outChan) <- liftIO $ newChan
  t1 <- lift . fork . void . runEffect $ p1 >-> (consumer inChan)
  t2 <- lift . fork . void . runEffect $ p2 >-> (consumer inChan)
  producer outChan
  where
    consumer :: (MonadIO m) => InChan a -> Consumer a m r
    consumer inChan = forever $ do
      msg <- await
      liftIO $ writeChan inChan msg

-- TODO: combineMany :: (MonadIO m, HasFork m) => [Producer a m r] -> Producer a m [r]

testCombine :: IO ()
testCombine = do
  runEffect $ (combine p1 p2) >-> P.stdoutLn
  where
    produce c = do
      liftIO $ threadDelay 10000000
      pure c
    p1 = P.replicateM 2 $ produce "a"
    p2 = P.replicateM 2 $ produce "b"

replicateP :: (MonadIO m, MonadIO n, HasFork n) => Producer a n r -> n [Producer a m r]
replicateP p = do
  (inChan1, outChan1) <- liftIO $ newChan
  (inChan2, outChan2) <- liftIO $ newChan
  t <- fork . void . runEffect $ p >-> (consumer inChan1 inChan2)
  pure $ [(producer outChan1), (producer outChan2)]
  where
    consumer :: (MonadIO m) => InChan a -> InChan a -> Consumer a m r
    consumer i1 i2 = forever $ do
      m <- await
      liftIO $ writeChan i1 m
      liftIO $ writeChan i2 m

testReplicate :: IO ()
testReplicate = do
  [p1, p2] <- replicateP p
  forkIO . runEffect $ p1 >-> P.stdoutLn
  forkIO . runEffect $ p2 >-> P.stdoutLn
  threadDelay 1000
  pure ()
  -- TODO: should wait for async of p1 and p2 to finish
  where
    produce c = do
      --liftIO $ threadDelay 10000000
      pure c
    p = P.replicateM 2 $ produce "a"

-- TODO: write tests to check performance and compare to pipes-concurrency
