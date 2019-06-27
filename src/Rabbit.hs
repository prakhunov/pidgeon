{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Rabbit
  ( createConnection,
    RabbitContext(..),
    RabbitMonad,
    runRabbitMonad,
    resetConnectionHandler,
  ) where

import Config (RabbitConfig(..), RabbitServer(..), ExchangeName)
import Network.Socket (PortNumber)
import qualified Network.AMQP as N (openConnection'', Connection, ConnectionOpts(..),
                                   plain, amqplain, declareExchange, newExchange,
                                   exchangeName, exchangeType, openChannel, closeChannel,
                                   addConnectionClosedHandler)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T (unpack)
import Control.Exception
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Monad.Reader

data RabbitContext = RabbitContext
  { ctxConnection :: MVar N.Connection,
    ctxExchangeName :: ExchangeName,
    ctxNewConnectionTimeout :: Int
  }

newtype RabbitMonad a = RabbitMonad (ReaderT RabbitContext IO a)
  deriving ( Functor
           , Applicative
           , Monad
           , MonadReader RabbitContext
           , MonadIO)

runRabbitMonad :: RabbitContext -> RabbitMonad a -> IO a
runRabbitMonad ctx (RabbitMonad m) = runReaderT m ctx


resetConnectionHandler :: MVar N.Connection -> RabbitConfig -> IO ()
resetConnectionHandler connRef rc = do
    putStrLn "Connection was closed, trying a new one for the next run."
    _ <- takeMVar connRef
    conn' <- createConnection rc
    N.addConnectionClosedHandler conn' True $ resetConnectionHandler connRef rc
    putMVar connRef conn'

convertServers :: [RabbitServer] -> [(String, PortNumber)]
convertServers = map sc
  where
    sc RabbitServer {host=h, port=Nothing} = (T.unpack h, 5672)
    sc RabbitServer {host=h, port=Just p} = (T.unpack h, p)

createCronExchange :: RabbitConfig -> N.Connection -> IO ()
createCronExchange config conn = do
  chan <- N.openChannel conn
  N.declareExchange chan $ N.newExchange {N.exchangeName = en, N.exchangeType = "direct"}
  N.closeChannel chan
  where
    en = exchangeName config


createConnection :: RabbitConfig -> IO N.Connection
createConnection config@RabbitConfig {virtualHost=vh, username=un,
                              password=p, connectionName=cn,
                              servers=s}
  = do
  let cno = N.ConnectionOpts {N.coServers=s', N.coVHost=vh, N.coAuth=auth,
                              N.coMaxFrameSize=Just 131072, N.coHeartbeatDelay=Just 15,
                              N.coMaxChannel=Nothing, N.coTLSSettings=Nothing,
                              N.coName=Just cn'}
  r <- try(N.openConnection'' cno) :: IO (Either SomeException N.Connection)
  -- TODO Catch only ConnectionException's and log the others
  case r of
    Left _ -> do
      putStrLn "Error opening connection, waiting 5 seconds."
      sleep
      createConnection config
    Right conn -> do
      e <- try(createCronExchange config conn) :: IO (Either SomeException ())
      case e of
        Left _ -> do
          putStrLn "Error creating an exchange, trying again in 5 seconds."
          sleep
          createConnection config
        Right _ -> do
          putStrLn "Opened a connection to RabbitMQ"
          return conn
  where
    auth = [N.plain un p, N.amqplain un p]
    cn' = fromMaybe "pidgeon" cn
    s' = convertServers s
    sleep = threadDelay 5000000
