{-# LANGUAGE OverloadedStrings #-}

module Lib
    ( runJobScheduler
    ) where

import qualified Network.AMQP as N
import Config(PidgeonConfig(..), CronConfig(..))
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
import Control.Exception

import Consul
import Network.Consul (destroySession)
import System.Exit (die)


printErrors :: [String] -> IO ()
printErrors [] = putStrLn "No errors found in the config file."
printErrors errors = mapM_ putStrLn errors


runWithConfig :: PidgeonConfig -> IO ()
runWithConfig config@PidgeonConfig{rabbit=rc, cron=CronConfig{schedules=cs, forceUniqueTimes=fut}, consul=consulConfig} = do
  let (errors , s) = partitionEithers $ createSchedules cs
  printErrors errors
  let uniqueSchedules = dedupEntriesByTime s
  let fut' = fromMaybe True fut

  case (fut', length uniqueSchedules == length s) of
    (True, False) -> die "This config file has forceUniqueSchedules set to true, and the schedules contain duplicate time entries. Exiting."
    _ -> do
      (consulClient, consulSession) <- acquireLock consulConfig
      restartApp <- newEmptyMVar
      (rabbitContext, conn) <- createRabbitContextAndConnection rc (refreshSession consulClient consulSession) (signalRestart restartApp)

      jobThreads <- runRabbitMonad rabbitContext $ do
        jobs <- crontabsToRabbitJobs s
        liftIO $ execSchedule $ do
          addJobsToSchedule jobs
          -- just in case there isn't a job that runs every minute add one of our own that just refreshes the consul session so the TTL doesn't expire
          addJob (consulRefreshJob consulClient consulSession restartApp) "* * * * *"

      putStrLn "Started pidgeon scheduler service"

      _ <- takeMVar restartApp
      putStrLn "Received an error from job threads, restarting..."

      mapM_ killThread jobThreads

      putStrLn "Finished destroying threads"
      -- close rabbit connection, ignore any errors since we are restarting anyways
      _ <- try(N.closeConnection conn) :: IO (Either SomeException ())

      -- destroy consul session (since the consul session gets destroyed if this is run in a HA environment,
      -- most likely another instance will pick up this failure)

      _ <- try(destroySession consulClient consulSession Nothing) :: IO (Either SomeException ())

      runWithConfig config
  where
    signalRestart restartVar errorMsg = do
      putStrLn "Restarting application due to the following error:"
      putStrLn errorMsg
      putMVar restartVar ()
    consulRefreshJob consulClient session restartApp = do
      refreshed <- refreshSession consulClient session
      if refreshed then
        return ()
      else
        signalRestart restartApp "Error refreshing consul session in maybe consul refresh job"

runJobScheduler :: IO ()
runJobScheduler = do
  -- TODO check length and have a helpful message if the config hasn't been specified
  configPath : _ <- getArgs
  config <- C.readConfig configPath
  runWithConfig config

