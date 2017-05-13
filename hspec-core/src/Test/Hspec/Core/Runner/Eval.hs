{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}

#if MIN_VERSION_base(4,6,0) && !MIN_VERSION_base(4,7,0)
-- Control.Concurrent.QSem is deprecated in base-4.6.0.*
{-# OPTIONS_GHC -fno-warn-deprecations #-}
#endif

module Test.Hspec.Core.Runner.Eval (
  EvalConfig(..)
, EvalTree
, EvalItem(..)
, runFormatter
#ifdef TEST
, runSequentially
#endif
) where

import           Prelude ()
import           Test.Hspec.Core.Compat hiding (Monad)
import qualified Test.Hspec.Core.Compat as M

import           Control.Monad (unless, when)
import qualified Control.Exception as E
import           Control.Concurrent
import           Control.Concurrent.Async hiding (cancel)

import           Control.Monad.IO.Class (liftIO)
import qualified Control.Monad.IO.Class as M

import           Control.Monad.Trans.State hiding (State, state)
import           Control.Monad.Trans.Class

import           Test.Hspec.Core.Util
import           Test.Hspec.Core.Spec (Tree(..), Location, Progress, FailureReason, Result(..), ProgressCallback)
import           Test.Hspec.Core.Timer
import           Test.Hspec.Core.Format

-- for compatibility with GHC < 7.10.1
class (Functor m, Applicative m, M.Monad m) => Monad m
instance (Functor m, Applicative m, M.Monad m) => Monad m
class (Monad m, M.MonadIO m) => MonadIO m
instance (Monad m, M.MonadIO m) => MonadIO m

data EvalConfig m = EvalConfig {
  evalConfigFormat :: Format m
, evalConfigConcurrentJobs :: Int
, evalConfigFastFail :: Bool
}

data State m = State {
  stateConfig :: EvalConfig m
, stateSuccessCount :: Int
, statePendingCount :: Int
, stateFailures :: [Path]
}

type EvalM m = StateT (State m) m

increaseSuccessCount :: Monad m => EvalM m ()
increaseSuccessCount = modify $ \state -> state {stateSuccessCount = stateSuccessCount state + 1}

increasePendingCount :: Monad m => EvalM m ()
increasePendingCount = modify $ \state -> state {statePendingCount = statePendingCount state + 1}

addFailure :: Monad m => Path -> EvalM m ()
addFailure path = modify $ \state -> state {stateFailures = path : stateFailures state}

getFormat :: Monad m => (Format m -> a) -> EvalM m a
getFormat format = gets (format . evalConfigFormat . stateConfig)

reportSuccess :: Monad m => Path -> String -> EvalM m ()
reportSuccess path details = do
  increaseSuccessCount
  format <- getFormat formatSuccess
  lift (format path details)

reportPending :: Monad m => Path -> Maybe String -> EvalM m ()
reportPending path reason = do
  increasePendingCount
  format <- getFormat formatPending
  lift (format path reason)

reportFailure :: Monad m => Maybe Location -> Path -> Either E.SomeException FailureReason -> EvalM m ()
reportFailure loc path err = do
  addFailure path
  format <- getFormat formatFailure
  lift $ format path loc err

reportResult :: Monad m => Path -> Maybe Location -> Either E.SomeException Result -> EvalM m ()
reportResult path loc result = do
  case result of
    Right (Success details) -> reportSuccess path details
    Right (Pending reason) -> reportPending path reason
    Right (Failure loc_ err) -> reportFailure (loc_ <|> loc) path (Right err)
    Left err -> reportFailure loc path (Left  err)

groupStarted :: Monad m => Path -> EvalM m ()
groupStarted path = do
  format <- getFormat formatGroupStarted
  lift $ format path

groupDone :: Monad m => Path -> EvalM m ()
groupDone path = do
  format <- getFormat formatGroupDone
  lift $ format path

data EvalItem = EvalItem {
  evalItemDescription :: String
, evalItemLocation :: Maybe Location
, evalItemParallelize :: Bool
, evalItemAction :: ProgressCallback -> IO (Either E.SomeException Result)
}

type EvalTree = Tree (IO ()) EvalItem

runEvalM :: Monad m => EvalConfig m -> EvalM m () -> m (State m)
runEvalM config action = execStateT action (State config 0 0 [])

-- | Evaluate all examples of a given spec and produce a report.
runFormatter :: forall m. MonadIO m => EvalConfig m -> [EvalTree] -> IO (Int, [Path])
runFormatter config specs = do
  let
    start = parallelizeTree (evalConfigConcurrentJobs config) specs
    cancel = cancelMany . concatMap toList . map (fmap fst)
  E.bracket start cancel $ \ runningSpecs -> do
    withTimer 0.05 $ \ timer -> do
      state <- formatRun format $ do
        runEvalM config $
          run $ map (fmap (fmap (. reportProgress timer) . snd)) runningSpecs
      let
        failures = stateFailures state
        total = stateSuccessCount state + statePendingCount state + length failures
      return (total, reverse failures)
  where
    format = evalConfigFormat config

    reportProgress :: IO Bool -> Path -> Progress -> m ()
    reportProgress timer path progress = do
      r <- liftIO timer
      when r (formatProgress format path progress)

cancelMany :: [Async a] -> IO ()
cancelMany asyncs = do
  mapM_ (killThread . asyncThreadId) asyncs
  mapM_ waitCatch asyncs

data Item a = Item {
  _itemDescription :: String
, _itemLocation :: Maybe Location
, _itemAction :: a
} deriving Functor

type Job m p a = (p -> m ()) -> m a

type RunningItem m = Item (Path -> m (Either E.SomeException Result))
type RunningTree m = Tree (IO ()) (RunningItem m)

type RunningItem_ m = (Async (), Item (Job m Progress (Either E.SomeException Result)))
type RunningTree_ m = Tree (IO ()) (RunningItem_ m)

data Semaphore = Semaphore {
  semaphoreWait :: IO ()
, semaphoreSignal :: IO ()
}

parallelizeTree :: MonadIO m => Int -> [EvalTree] -> IO [RunningTree_ m]
parallelizeTree n specs = do
  sem <- newQSem n
  mapM (traverse $ parallelizeItem sem) specs

parallelizeItem :: MonadIO m => QSem -> EvalItem -> IO (RunningItem_ m)
parallelizeItem sem EvalItem{..} = do
  (asyncAction, evalAction) <- parallelize (Semaphore (waitQSem sem) (signalQSem sem)) evalItemParallelize evalItemAction
  return (asyncAction, Item evalItemDescription evalItemLocation evalAction)

parallelize :: MonadIO m => Semaphore -> Bool -> Job IO p a -> IO (Async (), Job m p a)
parallelize sem isParallelizable
  | isParallelizable = runParallel sem
  | otherwise = runSequentially

runSequentially :: MonadIO m => Job IO p a -> IO (Async (), Job m p a)
runSequentially action = do
  mvar <- newEmptyMVar
  (asyncAction, evalAction) <- runParallel (Semaphore (takeMVar mvar) (return ())) action
  return (asyncAction, \ notifyPartial -> liftIO (putMVar mvar ()) >> evalAction notifyPartial)

data Parallel p a = Partial p | Return a

runParallel :: forall m p a. MonadIO m => Semaphore -> Job IO p a -> IO (Async (), Job m p a)
runParallel Semaphore{..} action = do
  mvar <- newEmptyMVar
  asyncAction <- async $ E.bracket_ semaphoreWait semaphoreSignal (worker mvar)
  return (asyncAction, eval mvar)
  where
    worker mvar = do
      let partialCallback = replaceMVar mvar . Partial
      result <- action partialCallback
      replaceMVar mvar (Return result)

    eval :: MVar (Parallel p a) -> (p -> m ()) -> m a
    eval mvar notifyPartial = do
      r <- liftIO (takeMVar mvar)
      case r of
        Partial p -> do
          notifyPartial p
          eval mvar notifyPartial
        Return result -> return result

replaceMVar :: MVar a -> a -> IO ()
replaceMVar mvar p = tryTakeMVar mvar >> putMVar mvar p

run :: forall m. MonadIO m => [RunningTree m] -> EvalM m ()
run specs = do
  fastFail <- gets (evalConfigFastFail . stateConfig)
  sequenceActions fastFail (concatMap foldSpec specs)
  where
    foldSpec :: RunningTree m -> [EvalM m ()]
    foldSpec = foldTree FoldTree {
      onGroupStarted = groupStarted
    , onGroupDone = groupDone
    , onCleanup = runCleanup
    , onLeafe = evalItem
    }

    runCleanup :: [String] -> IO () -> EvalM m ()
    runCleanup groups action = do
      r <- liftIO $ safeTry action
      either (reportFailure Nothing path . Left) return r
      where
        path = (groups, "afterAll-hook")

    evalItem :: [String] -> RunningItem m -> EvalM m ()
    evalItem groups (Item requirement loc action) = do
      lift (action path) >>= reportResult path loc
      where
        path :: Path
        path = (groups, requirement)

data FoldTree c a r = FoldTree {
  onGroupStarted :: Path -> r
, onGroupDone :: Path -> r
, onCleanup :: [String] -> c -> r
, onLeafe :: [String] -> a -> r
}

foldTree :: FoldTree c a r -> Tree c a -> [r]
foldTree FoldTree{..} = go []
  where
    go rGroups (Node group xs) = start : children ++ [done]
      where
        path = (reverse rGroups, group)
        start = onGroupStarted path
        children = concatMap (go (group : rGroups)) xs
        done =  onGroupDone path
    go rGroups (NodeWithCleanup action xs) = children ++ [cleanup]
      where
        children = concatMap (go rGroups) xs
        cleanup = onCleanup (reverse rGroups) action
    go rGroups (Leaf a) = [onLeafe (reverse rGroups) a]

sequenceActions :: Monad m => Bool -> [EvalM m ()] -> EvalM m ()
sequenceActions fastFail = go
  where
    go [] = return ()
    go (action : actions) = do
      () <- action
      hasFailures <- (not . null) <$> gets stateFailures
      let stopNow = fastFail && hasFailures
      unless stopNow (go actions)
