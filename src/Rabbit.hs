{-# LANGUAGE OverloadedStrings #-}

module Rabbit
  ( createConnection,
    createCronExchange
  ) where

import Config (RabbitConfig(..), RabbitServer(..))
import Network.Socket (PortNumber)
import qualified Network.AMQP as N (openConnection'', Connection, ConnectionOpts(..),
                                   plain, amqplain, declareExchange, newExchange,
                                   exchangeName, exchangeType, openChannel, closeChannel)
import Data.Maybe (maybe)
import qualified Data.Text as T (unpack)
import Control.Exception
import Control.Concurrent (threadDelay)



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
                            N.coMaxFrameSize=Just 131072, N.coHeartbeatDelay=Nothing,
                            N.coMaxChannel=Nothing, N.coTLSSettings=Nothing,
                            N.coName=Just cn'}
  r <- try(N.openConnection'' cno) :: IO (Either SomeException N.Connection)
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
        Right _ -> return conn
  where
    auth = [N.plain un p, N.amqplain un p]
    cn' = maybe "pidgeon" id cn
    s' = convertServers s
    sleep = threadDelay 5000000
