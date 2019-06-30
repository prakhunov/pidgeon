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
    ValidatedCrontabEntry
  ) where


import System.Cron.Parser (parseCrontabEntry)
import System.Cron.Types (CrontabEntry(..), CronCommand(..), CronSchedule(..))
import Config (ExchangeName)
import Data.Text (Text)
import System.Cron.Schedule
import Control.Monad.State

import qualified Data.Text as T (unpack)
import qualified Data.List as L (nubBy)

import Control.Monad.Reader
import Rabbit (RabbitContext(..), RabbitMonad, RoutingKey, invalidRoutingKey)


data ValidatedCrontabEntry = ValidatedCrontabEntry CronSchedule CronCommand

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

crontabToRabbitJob :: ValidatedCrontabEntry -> RabbitMonad Job
crontabToRabbitJob (ValidatedCrontabEntry t CronCommand{cronCommand=k}) = do
  RabbitContext sm <- ask
  return $ Job t $ sm k ""

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
