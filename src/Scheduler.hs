{-# LANGUAGE OverloadedStrings    #-}

module Scheduler
  ( dedupEntriesByTime,
    addJobToSchedule,
    addJobsToSchedule,
    crontabToRabbitJob,
    crontabsToRabbitJobs,
    createSchedules,
    RoutingKey,
    ExchangeName,
    ValidatedCrontabEntry(..)
  ) where


import System.Cron.Parser (parseCrontabEntry)
import System.Cron.Types (CrontabEntry(..), CronCommand(..), CronSchedule(..))
import Config (ExchangeName)
import Data.Text (Text)
import Network.AMQP (Channel, publishMsg, openChannel, newMsg, msgBody, closeChannel)
import System.Cron.Schedule
import Control.Monad.State
import Control.Concurrent.MVar
import Control.Exception
import Data.Time.Clock

import qualified Data.Text as T (length, all, unpack)
import qualified Data.Set as S (notMember, fromList)
import qualified Data.List as L (nubBy)
import qualified Data.Char as C (isAlphaNum)

import Control.Monad.Reader
import Rabbit (RabbitContext(..), RabbitMonad)

type RoutingKey = Text

data ValidatedCrontabEntry = ValidatedCrontabEntry CronSchedule CronCommand

validRoutingKey :: RoutingKey -> Bool
validRoutingKey k = T.length k <= 255 && T.length k > 0 && T.all valid k
  where
    invalidCharacters = S.fromList ['#', '*']
    valid c = (C.isAlphaNum c && S.notMember c invalidCharacters) || (c == '.')

invalidRoutingKey :: RoutingKey -> Bool
invalidRoutingKey = not . validRoutingKey

validateEntries :: [Either String CrontabEntry] -> [Either String ValidatedCrontabEntry]
validateEntries = map validate
  where
    validate (Right (CommandEntry s co@CronCommand{cronCommand=routingKey}))
      | invalidRoutingKey routingKey = Left ("Routing key is invalid: " ++ T.unpack routingKey ++ " for: " ++ show s)
      | otherwise = Right (ValidatedCrontabEntry s co)
    validate (Right (EnvVariable a b)) = Left ("Invalid cron entry: " ++ T.unpack a ++ T.unpack b)
    validate (Left e') = Left e'


dedupEntriesByTime :: [ValidatedCrontabEntry] -> [ValidatedCrontabEntry]
dedupEntriesByTime = L.nubBy timeEquals
  where
    timeEquals (ValidatedCrontabEntry t _) (ValidatedCrontabEntry t' _) = t == t'

createSchedules :: [Text] -> [Either String ValidatedCrontabEntry]
createSchedules = validateEntries . map parseCrontabEntry

rabbitJob :: RabbitContext -> RoutingKey -> IO ()
rabbitJob (RabbitContext connRef exch connTimeout) k = do
  beforeLock <- getCurrentTime
  conn' <- readMVar connRef
  afterLock <- getCurrentTime
  let timeDiffInSeconds = floor (afterLock `diffUTCTime` beforeLock) :: Int
  if timeDiffInSeconds < connTimeout then do
    c <- try(openChannel conn') :: IO (Either SomeException Channel)
    -- TODO log the exception's better
    case c of
      Left _ ->
        putStrLn $ "Got an error opening a channel, connection closed. Following job will run at it's next schedule: " ++ T.unpack k
      Right chan -> do
        r <- try(publishMsg chan exch k $ newMsg {msgBody = ""}) :: IO (Either SomeException (Maybe Int))
        case r of
          Left _ ->
            putStrLn $ "Got an error trying to publish a msg. Following job will run at it's next schedule: " ++ T.unpack k
          Right _ -> do
            putStrLn $ "Published following cron job: " ++ T.unpack k
            closeChannel chan
  else
    putStrLn $ "Took too long to get a rabbit connection not running the following job: " ++ T.unpack k


crontabToRabbitJob :: ValidatedCrontabEntry -> RabbitMonad Job
crontabToRabbitJob (ValidatedCrontabEntry t CronCommand{cronCommand=k}) = do
  context <- ask
  return $ Job t $ rabbitJob context k

crontabsToRabbitJobs :: [ValidatedCrontabEntry] -> RabbitMonad [Job]
crontabsToRabbitJobs = mapM crontabToRabbitJob

addJobToSchedule :: Job -> Schedule ()
addJobToSchedule j = do
  js <- get
  put $ j : js

addJobsToSchedule :: [Job] -> Schedule ()
addJobsToSchedule j = do
  js <- get
  put $ j ++ js
