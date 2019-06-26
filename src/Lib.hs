{-# LANGUAGE OverloadedStrings #-}

module Lib
    ( someFunc
    ) where

import qualified Network.AMQP as N
import Config(PidgeonConfig(..), CronConfig(..), RabbitConfig(..))
import qualified Config as C

import System.Cron.Schedule
import Scheduler
import Control.Concurrent.MVar
import Rabbit (createConnection, createCronExchange)
import Control.Concurrent.Event ( Event )
import Control.Concurrent (forkIO)
import qualified Control.Concurrent.Event as E
import System.Environment



-- TODO instead of passing the mvar'ed connection and event around, use this object and make a reader monad
data RabbitContext = RabbitContext
  { connection :: MVar N.Connection,
    exceptionEvent :: Event
  }


resetConnection :: MVar N.Connection -> RabbitConfig -> IO ()
resetConnection connRef rc = do
    putStrLn "Connection was closed, trying a new one for the next run."
    _ <- takeMVar connRef
    conn' <- createConnection rc
    putMVar connRef conn'


waitForConnectionException :: Event -> MVar N.Connection -> RabbitConfig -> IO ()
waitForConnectionException e connRef rc = do
  E.wait e
  resetConnection connRef rc
  E.clear e
  waitForConnectionException e connRef rc

-- TODO rename this to something else
someFunc :: IO ()
someFunc = do
  configPath : _ <- getArgs
  PidgeonConfig{rabbit=rc, cron=CronConfig{schedules=cs, forceUniqueTimes=fum}} <- C.readConfig configPath
  -- TODO print out the errors
  let (_, s) = createSchedules cs
  let uniqueSchedules = dedupEntriesByTime s
  let fu = maybe True id fum

  case (fu, length uniqueSchedules == length s) of
    (True, False) -> error "This config file has forceUniqueSchedules set to true, and the schedules contain duplicate time entries. Exiting"
    _ -> do
      let en = exchangeName rc
      conn <- createConnection rc
      connRef <- newMVar conn
      -- for when rabbitmq servers cleanly close the connection
      N.addConnectionClosedHandler conn True $ resetConnection connRef rc

      ce <- E.new
      let jobs = crontabsToRabbitJobs (connRef, en, ce) s

      _ <- execSchedule $ do
        addJobsToSchedule jobs

      --the connection cloesdhandler doesn't always fire when an exception is thrown
      --even though the Network.AMQP library says it should so
      _ <- forkIO $ waitForConnectionException ce connRef rc

      putStrLn "Started pidgeon scheduler service"
      -- TODO have it wait for a normal kill signal
      _ <- getLine
      N.closeConnection conn
      return ()
