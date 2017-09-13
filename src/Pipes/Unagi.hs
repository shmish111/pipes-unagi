{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Pipes.Unagi where

import           Control.Concurrent.Async.Lifted (Async, async, poll, wait,
                                                  waitBoth)
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

-- | Convert an OutChan into a Producer. Once the OutChan produces 'Nothing', the Producer will close, returning ()
newProducer :: (MonadIO m) => OutChan (Maybe a) -> Producer a m ()
newProducer outChan = do
  ma <- liftIO $ readChan outChan
  case ma of
    Just a -> do
      yield a
      newProducer outChan
    Nothing -> return ()

-- | Take 2 Producers and merge their outputs.
--   There is no guarantee to the ordering.
-- TODO: Exceptions:
--   The return value is a tuple of the return values of each 'Producer' which can be an 'Exception' since we have to go into 'IO' and do things in parallel but if one 'Producer' throws an exception, we don't want to stop the other one. Or do we? Maybe we should cancel the other one.
merge ::
     (MonadIO m, HasFork m, MonadBaseControl IO m)
  => Producer a m r
  -> Producer a m r
  -> Producer a m (Either SomeException r, Either SomeException r)
merge p1 p2 = do
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

testMerge :: IO ()
testMerge = do
  runEffect $ merge p1 p2 >-> pstdoutLn
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

-- | Create 2 Producers that both yield what the input Producer yields
clone ::
     (MonadIO m, MonadBaseControl IO m)
  => Producer a m r
  -> m (Producer a m r, Producer a m r)
clone p = do
  (inChan1, outChan1) <- liftIO newChan
  (inChan2, outChan2) <- liftIO newChan
  a <-
    async $ do
      r <- runEffect $ p >-> P.map Just >-> consumer inChan1 inChan2
      runEffect $ produceNothing r >-> consumer inChan1 inChan2
      pure r
  pure (producer a outChan1, producer a outChan2)
  where
    produceNothing v = do
      yield Nothing
      return v
    consumer :: (MonadIO m) => InChan a -> InChan a -> Consumer a m r
    consumer i1 i2 =
      forever $ do
        m <- await
        liftIO $ writeChan i1 m
        liftIO $ writeChan i2 m
    producer ::
         (MonadIO m, MonadBaseControl IO m)
      => Async (StM m r)
      -> OutChan (Maybe a)
      -> Producer a m r
    producer a outChan = do
      mMsg <- liftIO $ readChan outChan
      case mMsg of
        Just msg -> do
          yield msg
          producer a outChan
        Nothing -> do
          v <- lift $ wait a
          pure v

testClone :: IO ()
testClone = do
  let p = P.replicateM 2 $ pure "a"
  (p1, p2) <- clone p
  a1 <- async . void . runEffect $ p1 >-> P.stdoutLn
  a2 <- async . void . runEffect $ p2 >-> P.stdoutLn
  waitBoth a1 a2
  pure ()
-- TODO: write tests to check performance and compare to pipes-concurrency
