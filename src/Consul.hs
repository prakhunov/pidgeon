{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Consul
  ( initConsul,
    acquireLock,
    ttlFunc
  ) where

import Config(ConsulConfig(..))

import Network.Consul
import Control.Concurrent (threadDelay)

initConsul :: ConsulConfig -> IO ConsulClient
initConsul ConsulConfig{consulHost=h, consulHttpPort=p, consulTls=True  } = initializeTlsConsulClient h p Nothing
initConsul ConsulConfig{consulHost=h, consulHttpPort=p, consulTls=False } = initializeConsulClient h p Nothing


ttlFunc :: ConsulClient -> Session -> IO ()
ttlFunc c s = do
  putStrLn "Refreshing consul session"
  _ <- renewSession c s Nothing
  return ()

--this is a blocking method and won't return until it has acquired a consul lock
acquireLock :: ConsulConfig -> IO (ConsulClient, Session)
acquireLock config = do
  c <- initConsul config
  session' <- createSession c sr Nothing
  case session' of
    Just session -> do
      gotLock <- putKeyAcquireLock c lockKey session Nothing
      if gotLock then do
        putStrLn "Acquired a consul lock."
        return (c, session)
      else do
        destroySession c session Nothing
        putStrLn "Couldn't get a consul lock, retrying in 5 seconds."
        sleep
        acquireLock config
    Nothing -> do
      putStrLn "Error getting a consul session retrying in 5 seconds."
      sleep
      acquireLock config
  where
    sr = SessionRequest{srLockDelay=Nothing, srName=Just "pidgeon", srNode=Nothing, srChecks = [], srBehavor=Nothing, srTtl=Just "90s"}
    lockKey = KeyValuePut{kvpKey = "pidgeon-lock", kvpValue = "", kvpCasIndex=Nothing, kvpFlags=Nothing}
    sleep = threadDelay 5000000
