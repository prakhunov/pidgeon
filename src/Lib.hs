{-# LANGUAGE OverloadedStrings #-}

module Lib
    ( runJobScheduler
    ) where

import qualified Network.AMQP as N
import Config(PidgeonConfig(..), CronConfig(..), RabbitConfig(..))
import qualified Config as C

import System.Cron.Schedule
import Scheduler
import Control.Concurrent.MVar
import Rabbit
import System.Environment
import Data.Maybe (fromMaybe)
import Data.Either (partitionEithers)
import Control.Monad.Reader (liftIO)



printErrors :: [String] -> IO ()
printErrors [] = putStrLn "No errors found in the config file."
printErrors errors = mapM_ putStrLn errors


-- TODO connect to Consul so you can use it for distributed locking (then you can run this app on multiple machines for HA)
-- TODO work with Rabbit over TLS
-- TODO work with Consul over TLS

runJobScheduler :: IO ()
runJobScheduler = do
  -- TODO check length and have a helpful message if the config hasn't been specified
  configPath : _ <- getArgs
  PidgeonConfig{rabbit=rc, cron=CronConfig{schedules=cs, forceUniqueTimes=fut, newConnectionTimeout=nct}} <- C.readConfig configPath
  let (errors , s) = partitionEithers $ createSchedules cs
  printErrors errors
  let uniqueSchedules = dedupEntriesByTime s
  let fut' = fromMaybe True fut

  case (fut', length uniqueSchedules == length s) of
    (True, False) -> error "This config file has forceUniqueSchedules set to true, and the schedules contain duplicate time entries. Exiting."
    _ -> do
      let en = exchangeName rc
      conn <- createConnection rc
      connRef <- newMVar conn

      N.addConnectionClosedHandler conn True $ resetConnectionHandler connRef rc
      let rabbitContext = RabbitContext connRef en nct

      _ <- runRabbitMonad rabbitContext $ do
        jobs <- crontabsToRabbitJobs s
        liftIO $ execSchedule $
          addJobsToSchedule jobs

      putStrLn "Started pidgeon scheduler service"
      -- TODO have it wait for a normal kill signal
      _ <- getLine
      N.closeConnection conn
