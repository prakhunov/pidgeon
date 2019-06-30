{-# LANGUAGE OverloadedStrings #-}

module Consul
  ( initConsul,
    acquireLock,
    ttlFunc
  ) where

import Config(ConsulConfig(..))

import Network.Consul
import Control.Concurrent (threadDelay)
import Control.Exception

initConsul :: ConsulConfig -> IO ConsulClient
initConsul ConsulConfig{consulHost=h, consulHttpPort=p, consulTls=True  } = initializeTlsConsulClient h p Nothing
initConsul ConsulConfig{consulHost=h, consulHttpPort=p, consulTls=False } = initializeConsulClient h p Nothing

ttlFunc :: ConsulConfig -> Session -> IO Bool
ttlFunc config s = do
  c <- initConsul config
  putStrLn "Refreshing consul session"
  r <- try(renewSession c s Nothing) :: IO (Either SomeException Bool)
  case r of
    Right True -> do
      putStrLn "Refreshed consul session"
      return True
    _ ->
      return False

--this is a blocking method and won't return until it has acquired a consul lock
acquireLock :: ConsulConfig -> IO Session
acquireLock config = do
  c <- initConsul config
  session' <- try(createSession c sr Nothing) :: IO (Either SomeException (Maybe Session))
  case session' of
    Right (Just session) -> do
      gotLock <- try(putKeyAcquireLock c lockKey session Nothing) :: IO (Either SomeException Bool)
      case gotLock of
        Right True -> do
          putStrLn "Acquired a consul lock."
          return session
        Right False -> do
          -- if destroying a session fails while trying to acquire the lock worked that means the connection to consul died
          -- so still retry
          _ <- try(destroySession c session Nothing) :: IO (Either SomeException ())
          lockError "Couldn't get a consul lock, retrying in 5 seconds."
        Left _ ->
          lockError "Couldn't get a consul lock, retrying in 5 seconds."
    _ ->
      lockError "Couldn't get a consul session, retrying in 5 seconds."
  where
    lockName = consulLockName config
    sr = SessionRequest{srLockDelay= Just "2s", srName=Just "pidgeon", srNode=Nothing, srChecks = ["serfHealth"], srBehavor=Nothing, srTtl=Just "90s"}
    lockKey = KeyValuePut{kvpKey = lockName, kvpValue = "", kvpCasIndex=Nothing, kvpFlags=Nothing}
    sleep = threadDelay 5000000
    lockError errorMsg = do
          putStrLn errorMsg
          sleep
          acquireLock config
