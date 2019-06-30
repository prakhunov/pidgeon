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
import Control.Concurrent (killThread)
import Rabbit
import System.Environment
import Data.Maybe (fromMaybe)
import Data.Either (partitionEithers)
import Control.Monad.Reader (liftIO)

import Consul
import System.Exit (die)


printErrors :: [String] -> IO ()
printErrors [] = putStrLn "No errors found in the config file."
printErrors errors = mapM_ putStrLn errors


runWithConfig :: PidgeonConfig -> IO ()
runWithConfig config@PidgeonConfig{rabbit=rc, cron=CronConfig{schedules=cs, forceUniqueTimes=fut, newConnectionTimeout=nct}, consul=consulConfig} = do

  let (errors , s) = partitionEithers $ createSchedules cs
  printErrors errors
  let uniqueSchedules = dedupEntriesByTime s
  let fut' = fromMaybe True fut

  case (fut', length uniqueSchedules == length s) of
    (True, False) -> die "This config file has forceUniqueSchedules set to true, and the schedules contain duplicate time entries. Exiting."
    _ -> do
      consulSession <- acquireLock consulConfig

      let en = exchangeName rc
      conn <- createConnection rc
      connRef <- newMVar conn
      restartApp <- newEmptyMVar
      N.addConnectionClosedHandler conn True $ resetConnectionHandler connRef rc
      let rabbitContext = RabbitContext connRef en nct (ttlFunc consulConfig consulSession) restartApp

      jobThreads <- runRabbitMonad rabbitContext $ do
        jobs <- crontabsToRabbitJobs s
        liftIO $ execSchedule $ do
          addJobsToSchedule jobs
          -- just in case there isn't a job that runs every minute add one of our own that just refreshes the consul session so the TTL doesn't expire
          addJob (consulRefreshJob consulSession restartApp) "* * * * *"

      putStrLn "Started pidgeon scheduler service"
      _ <- takeMVar restartApp
      putStrLn "Received an error from job threads, restarting..."
      mapM_ killThread jobThreads
      putStrLn "Finished destroying threads"
      N.closeConnection conn
      runWithConfig config
  where
    consulRefreshJob session restartApp = do
      refreshed <- ttlFunc consulConfig session
      if refreshed then
        return ()
      else
        putMVar restartApp ()

runJobScheduler :: IO ()
runJobScheduler = do
  -- TODO check length and have a helpful message if the config hasn't been specified
  configPath : _ <- getArgs
  config <- C.readConfig configPath
  runWithConfig config

