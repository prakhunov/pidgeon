{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Rabbit
  ( RabbitContext(..),
    RabbitMonad,
    createRabbitContextAndConnection,
    runRabbitMonad,
    RoutingKey,
    validRoutingKey,
    invalidRoutingKey
  ) where

import Config (RabbitConfig(..), RabbitServer(..), ExchangeName)
import Network.Socket (PortNumber)
import qualified Network.AMQP as N (openConnection'', Connection, ConnectionOpts(..),
                                   plain, amqplain, declareExchange, newExchange,
                                   exchangeName, exchangeType, openChannel, closeChannel,
                                   TLSSettings(..), Channel, msgBody, publishMsg, newMsg,
                                   addConnectionClosedHandler)

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T (unpack, length, all)
import qualified Data.ByteString.Lazy.Char8 as BL (pack)
import qualified Data.Set as S (notMember, fromList)
import qualified Data.Char as C (isAlphaNum)
import Control.Exception
import Control.Concurrent (threadDelay)
import Control.Monad.Reader


newtype RabbitContext = RabbitContext
  { sendMessage :: RoutingKey -> String -> IO ()
  }

newtype RabbitMonad a = RabbitMonad (ReaderT RabbitContext IO a)
  deriving ( Functor
           , Applicative
           , Monad
           , MonadReader RabbitContext
           , MonadIO)

runRabbitMonad :: RabbitContext -> RabbitMonad a -> IO a
runRabbitMonad ctx (RabbitMonad m) = runReaderT m ctx


type RoutingKey = Text
-- config, consul lock refresh function
type ConsulRefresh = IO Bool
type RestartHandler = String -> IO ()

validRoutingKey :: RoutingKey -> Bool
validRoutingKey k = T.length k <= 255 && T.length k > 0 && T.all valid k
  where
    invalidCharacters = S.fromList ['#', '*']
    valid c = (C.isAlphaNum c && S.notMember c invalidCharacters) || (c == '.')

invalidRoutingKey :: RoutingKey -> Bool
invalidRoutingKey = not . validRoutingKey

createRabbitContextAndConnection :: RabbitConfig -> ConsulRefresh -> RestartHandler -> IO (RabbitContext, N.Connection)
createRabbitContextAndConnection config consulHandler restartHandler = do
  connection <- createConnection config
  N.addConnectionClosedHandler connection False $ restartHandler "Rabbit connection was closed"
  return (RabbitContext $ sendMessage' connection consulHandler restartHandler exchange, connection)
  where
    exchange = exchangeName config


sendMessage' :: N.Connection -> ConsulRefresh -> RestartHandler -> ExchangeName -> RoutingKey -> String -> IO ()
sendMessage' conn consulRefresh restartHandler exch k message = do
  refreshed <- consulRefresh
  if refreshed then do
    c <- try(N.openChannel conn) :: IO (Either SomeException N.Channel)
    -- TODO log the exception's better
    case c of
      Left _ ->
        restartHandler $ "Got an error opening a channel, connection closed. Restarting application while running: " ++ T.unpack k
      Right chan -> do
        r <- try(N.publishMsg chan exch k $ N.newMsg {N.msgBody = BL.pack message}) :: IO (Either SomeException (Maybe Int))
        case r of
          Left _ ->
            restartHandler $ "Got an error publishing a message, connection closed. Restarting application while running: : " ++ T.unpack k
          Right _ -> do
            putStrLn $ "Published following cron job: " ++ T.unpack k
            closed <- try(N.closeChannel chan) :: IO (Either SomeException ())
            case closed of
              Left _ ->
                restartHandler "Got an error closing a channel, restarting application."
              _ -> return ()
  else
    restartHandler $ "Restarting application due to not being able to refresh a consul session for: " ++ T.unpack k

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
                              servers=s,rabbitTls=isTls}
  = do
  let cno = N.ConnectionOpts {N.coServers=s', N.coVHost=vh, N.coAuth=auth,
                              N.coMaxFrameSize=Just 131072, N.coHeartbeatDelay=Just 15,
                              N.coMaxChannel=Nothing, N.coTLSSettings=tlsSetting,
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
    tlsSetting = if isTls then Just N.TLSTrusted else Nothing
