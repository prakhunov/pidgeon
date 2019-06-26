{-# LANGUAGE OverloadedStrings    #-}

module Scheduler
  ( dedupEntriesByTime,
    createSchedules,
    addJobsToSchedule,
    addJobToSchedule,
    crontabToRabbitJob,
    crontabsToRabbitJobs,
    RoutingKey,
    ExchangeName
  ) where


import System.Cron.Parser (parseCrontabEntry)
import System.Cron.Types (CrontabEntry(..), CronCommand(..), CronSchedule(..))
import Config (ExchangeName)
import Data.Text (Text)
import Network.AMQP (Connection, Channel, publishMsg, openChannel, newMsg, msgBody, closeChannel)
import System.Cron.Schedule
import Control.Monad.State
import Control.Concurrent.MVar
import Control.Exception

import qualified Data.Text as T (length, all, unpack)
import qualified Data.Set as S (notMember, fromList)
import qualified Data.List as L (nubBy, foldl')
import qualified Data.Char as C (isAlphaNum)

import Control.Concurrent.Event ( Event )
import qualified Control.Concurrent.Event as E

type RoutingKey = Text

data ValidatedCrontabEntry = ValidatedCrontabEntry CronSchedule CronCommand

validRoutingKey :: RoutingKey -> Bool
validRoutingKey k = T.length k <= 255 && T.length k > 0 && T.all valid k
  where
    invalidCharacters = S.fromList ['#', '*']
    valid c = (C.isAlphaNum c && S.notMember c invalidCharacters) || (c == '.')

invalidRoutingKey :: RoutingKey -> Bool
invalidRoutingKey = not . validRoutingKey

splitEntries :: [Either String CrontabEntry] -> ([String], [ValidatedCrontabEntry])
splitEntries = L.foldl' collect ([],[])
  where
    collect (errorList, commandList) (Right (CommandEntry s co@CronCommand{cronCommand=routingKey}))
      | invalidRoutingKey routingKey = (("Routing key is invalid: " ++ T.unpack routingKey ) : errorList, commandList)
      | otherwise = (errorList, ValidatedCrontabEntry s co : commandList)
    collect (errorList, commandList) (Right (EnvVariable a b)) = (("Invalid cron entry: " ++ T.unpack a ++ T.unpack b) : errorList, commandList)
    collect (errorList, commandList) (Left err) = (err : errorList, commandList)


dedupEntriesByTime :: [ValidatedCrontabEntry] -> [ValidatedCrontabEntry]
dedupEntriesByTime = L.nubBy timeEquals
  where
    timeEquals (ValidatedCrontabEntry t _) (ValidatedCrontabEntry t' _) = t == t'

createSchedules :: [Text] -> ([String], [ValidatedCrontabEntry])
createSchedules = splitEntries . map parseCrontabEntry

rabbitJob :: (MVar Connection, ExchangeName, Event) -> RoutingKey -> IO ()
rabbitJob (conn, exchangeName, e) k = do
  conn' <- readMVar conn
  c <- try(openChannel conn') :: IO (Either SomeException Channel)
  case c of
    Left _ -> do
      putStrLn $ "Got an error opening a channel, connection closed."
      E.set e
    Right chan -> do
      r <- try(publishMsg chan exchangeName k $ newMsg {msgBody = ""}) :: IO (Either SomeException (Maybe Int))
      case r of
        Left _ -> do
          putStrLn $ "Got an error trying to publish a msg"
          E.set e
        Right _ -> do
          putStrLn $ "Published following cron job: " ++ T.unpack k
          closeChannel chan

crontabToRabbitJob :: (MVar Connection, ExchangeName, Event) -> ValidatedCrontabEntry -> Job
crontabToRabbitJob c (ValidatedCrontabEntry t CronCommand{cronCommand=r}) = Job t (rabbitJob c r)

crontabsToRabbitJobs :: (MVar Connection, ExchangeName, Event) -> [ValidatedCrontabEntry] -> [Job]
crontabsToRabbitJobs = map . crontabToRabbitJob

addJobToSchedule :: Job -> Schedule ()
addJobToSchedule j = do
  js <- get
  put $ j : js

addJobsToSchedule :: [Job] -> Schedule ()
addJobsToSchedule j = do
  js <- get
  put $ j ++ js
