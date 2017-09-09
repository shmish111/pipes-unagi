{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Pipes.Unagi where

import           Control.Concurrent.Async.Lifted (Async, async, poll, waitBoth)
import           Control.Concurrent.Chan.Unagi   (InChan, OutChan, newChan,
                                                  readChan, writeChan)
import           Control.Concurrent.MonadIO      (HasFork, MonadIO, fork,
                                                  forkIO, liftIO, threadDelay)
import           Control.Exception.Base          (SomeException)
import           Control.Monad                   (forever, void)
import           Control.Monad.Trans.Class       (lift)
import           Control.Monad.Trans.Control     (MonadBaseControl, StM)
import           Pipes                           (Consumer, Producer, await,
                                                  runEffect, yield, (>->))
import qualified Pipes.Prelude                   as P

combine ::
     (MonadIO m, HasFork m, MonadBaseControl IO m)
  => Producer a m r
  -> Producer a m r
  -> Producer a m (Either SomeException r, Either SomeException r)
combine p1 p2 = do
  (inChan, outChan) <- liftIO newChan
  a1 <- lift . async . runEffect $ p1 >-> consumer inChan
  a2 <- lift . async . runEffect $ p2 >-> consumer inChan
  producer a1 a2 outChan
  where
    consumer :: (MonadIO m) => InChan a -> Consumer a m r
    consumer inChan =
      forever $ do
        msg <- await
        liftIO $ writeChan inChan msg
    producer ::
         (MonadIO m, MonadBaseControl IO m)
      => Async (StM m r)
      -> Async (StM m r)
      -> OutChan a
      -> Producer a m (Either SomeException r, Either SomeException r)
    producer a1 a2 outChan = do
      mv1 <- lift $ poll a1
      mv2 <- lift $ poll a2
      case (mv1, mv2) of
        (Just v1, Just v2) -> do
          msg <- liftIO $ readChan outChan
          yield msg
          pure (v1, v2)
        _ -> do
          msg <- liftIO $ readChan outChan
          yield msg
          producer a1 a2 outChan

-- TODO: combineMany :: (MonadIO m, HasFork m) => [Producer a m r] -> Producer a m [r]
testCombine :: IO ()
testCombine = do
  runEffect $ combine p1 p2 >-> pstdoutLn
  pure ()
  where
    pstdoutLn =
      forever $ do
        a <- await
        liftIO $ putStrLn a
        pure ((), ())
    produce c = do
      liftIO $ threadDelay 1000000
      pure c
    p1 = P.replicateM 2 $ produce "a"
    p2 = P.replicateM 2 $ produce "b"

replicateP ::
     (MonadIO n, MonadBaseControl IO n)
  => Producer a n r
  -> n [Producer a n (Either SomeException r)]
replicateP p = do
  (inChan1, outChan1) <- liftIO newChan
  (inChan2, outChan2) <- liftIO newChan
  a <- async . runEffect $ p >-> consumer inChan1 inChan2
  pure [producer a outChan1, producer a outChan2]
  where
    consumer :: (MonadIO m) => InChan a -> InChan a -> Consumer a m r
    consumer i1 i2 =
      forever $ do
        m <- await
        liftIO $ writeChan i1 m
        liftIO $ writeChan i2 m
    producer ::
         (MonadIO m, MonadBaseControl IO m)
      => Async (StM m r)
      -> OutChan a
      -> Producer a m (Either SomeException r)
    producer a outChan = do
      mv <- lift $ poll a
      case mv of
        Nothing -> do
          liftIO $ putStrLn "nowt"
          msg <- liftIO $ readChan outChan
          yield msg
          producer a outChan
        Just v -> do
          liftIO $ putStrLn "just"
          msg <- liftIO $ readChan outChan
          yield msg
          pure v

testReplicate :: IO ()
testReplicate = do
  [p1, p2] <- replicateP p
  a1 <- async . void . runEffect $ p1 >-> consumer
  a2 <- async . void . runEffect $ p2 >-> consumer
  waitBoth a1 a2
  pure ()
  where
    produce c = do
      liftIO $ threadDelay 1000000
      pure c
    p = P.replicateM 2 $ produce "a"
    consumer =
      forever $ do
        esv <- await
        liftIO $ print esv
-- TODO: this test isn't working properly
-- TODO: write tests to check performance and compare to pipes-concurrency
