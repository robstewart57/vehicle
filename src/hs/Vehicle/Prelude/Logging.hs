{-# LANGUAGE GeneralisedNewtypeDeriving #-}

module Vehicle.Prelude.Logging
  ( Severity
  , Message(..)
  , MonadLogger(incrCallDepth, decrCallDepth, logMessage)
  , LoggerT
  , Logger
  , runLoggerT
  , runLogger
  , discardWarningsAndLogs
  , outputWarningsAndDiscardLogs
  , logWarning
  , logInfo
  , logDebug
  , logOutput
  , liftExceptWithLogging
  , flushLogger
  , showMessages
  , setTextColour
  , setBackgroundColour
  ) where

import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.State (StateT(..), get, modify, evalStateT)
import Control.Monad.Writer (WriterT, tell, runWriterT)
import Control.Monad.Identity (Identity, runIdentity)
import Control.Monad.Except (MonadError(..), Except, ExceptT, mapExceptT)
import Control.Monad.Reader (ReaderT)
import Data.Text (Text)
import Data.Text qualified as T
import System.Console.ANSI

import Vehicle.Prelude.Prettyprinter
import Vehicle.Prelude.Supply (SupplyT)

data Severity
  = Debug
  | Info
  | Warning
  | ProgramOutput
  deriving (Eq, Ord)

setTextColour :: Color -> String -> String
setTextColour c s =
  setSGRCode [SetColor Foreground Vivid c] <>
  s <>
  setSGRCode [SetColor Foreground Vivid White]

setBackgroundColour :: Color -> String -> String
setBackgroundColour c s =
  setSGRCode [SetColor Background Vivid c] <>
  s <>
  setSGRCode [SetColor Background Vivid Black]

severityColour :: Severity -> Maybe Color
severityColour = \case
  Warning        -> Just Yellow
  Info           -> Just Blue
  Debug          -> Just Green
  ProgramOutput  -> Nothing

severityPrefix :: Severity -> Text
severityPrefix Warning        = "Warning: "
severityPrefix Info           = "Info: "
severityPrefix Debug          = ""
severityPrefix ProgramOutput  = ""

type CallDepth = Int

data Message = Message
  { severityOf :: Severity
  , textOf     :: Text
  }

class Monad m => MonadLogger m where
  getCallDepth  :: m CallDepth
  incrCallDepth :: m ()
  decrCallDepth :: m ()
  logMessage    :: Message -> m ()

newtype LoggerT m a = LoggerT
  { unloggerT :: WriterT [Message] (StateT Int m) a
  } deriving (Functor, Applicative, Monad)

type Logger = LoggerT Identity

instance Monad m => MonadLogger (LoggerT m) where
  getCallDepth  = LoggerT get
  incrCallDepth = LoggerT $ modify (+1)
  decrCallDepth = LoggerT $ modify (\x -> x-1)
  logMessage m  = LoggerT $ tell [m]

instance MonadLogger m => MonadLogger (StateT s m) where
  getCallDepth  = lift getCallDepth
  incrCallDepth = lift incrCallDepth
  decrCallDepth = lift decrCallDepth
  logMessage    = lift . logMessage

instance MonadLogger m => MonadLogger (ReaderT s m) where
  getCallDepth  = lift getCallDepth
  incrCallDepth = lift incrCallDepth
  decrCallDepth = lift decrCallDepth
  logMessage    = lift . logMessage

instance (Monoid w, MonadLogger m) => MonadLogger (WriterT w m) where
  getCallDepth  = lift getCallDepth
  incrCallDepth = lift incrCallDepth
  decrCallDepth = lift decrCallDepth
  logMessage    = lift . logMessage

instance (MonadLogger m) => MonadLogger (ExceptT e m) where
  getCallDepth  = lift getCallDepth
  incrCallDepth = lift incrCallDepth
  decrCallDepth = lift decrCallDepth
  logMessage    = lift . logMessage

instance MonadLogger m => MonadLogger (SupplyT s m) where
  getCallDepth  = lift getCallDepth
  incrCallDepth = lift incrCallDepth
  decrCallDepth = lift decrCallDepth
  logMessage    = lift . logMessage

instance MonadTrans LoggerT where
  lift = LoggerT . lift . lift

instance MonadError e m => MonadError e (LoggerT m) where
  throwError     = lift . throwError
  catchError m f = LoggerT (catchError (unloggerT m) (unloggerT . f))

runLoggerT :: Monad m => LoggerT m a -> m (a, [Message])
runLoggerT (LoggerT logger) = evalStateT (runWriterT logger) 0

runLogger :: Logger a -> (a, [Message])
runLogger = runIdentity . runLoggerT

discardWarningsAndLogs :: Logger a -> a
discardWarningsAndLogs m = fst $ runLogger m

outputWarningsAndDiscardLogs :: Logger a -> IO a
outputWarningsAndDiscardLogs logger = do
  let (value, messages) = runLogger logger
  let warnings = filter (\msg -> severityOf msg == Warning) messages
  printMessagesToStdout warnings
  return value

logOutput :: MonadLogger m => Doc a -> m ()
logOutput text = logMessage $ Message ProgramOutput (layoutAsText text)

logWarning :: MonadLogger m => Doc a -> m ()
logWarning text = logMessage $ Message Warning (layoutAsText text)

logInfo :: MonadLogger m => Doc a -> m ()
logInfo text = logMessage $ Message Info (layoutAsText text)

logDebug :: MonadLogger m => Doc a -> m ()
logDebug text = do
  depth <- getCallDepth
  logMessage $ Message Debug (layoutAsText (indent depth text))

instance Show Message where
  show (Message s t) =
    let txt = T.unpack (severityPrefix s <> t) in
    maybe txt (`setTextColour` txt) (severityColour s)

showMessages :: [Message] -> String
showMessages logs = unlines $ map show logs

liftExceptWithLogging :: Except e v -> ExceptT e Logger v
liftExceptWithLogging = mapExceptT (pure . runIdentity)

flushLogger :: Maybe FilePath -> Logger a -> IO a
flushLogger logLocation l = do
  let (v, messages) = runLogger l
  flushLogs logLocation messages
  return v

flushLogs :: Maybe FilePath -> [Message] -> IO ()
flushLogs Nothing        = printMessagesToStdout
flushLogs (Just logFile) = writeMessageToFile logFile

printMessagesToStdout :: [Message] -> IO ()
printMessagesToStdout = mapM_ print

writeMessageToFile :: FilePath -> [Message] -> IO ()
writeMessageToFile logFile logs = appendFile logFile (showMessages logs)