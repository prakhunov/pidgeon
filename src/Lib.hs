{-# LANGUAGE OverloadedStrings #-}

module Lib
    ( someFunc
    ) where

import Network.AMQP
import Data.Text
import Data.String
import qualified Data.ByteString.Lazy.Char8 as BL


type ExchangeName = Text

createCronExchange :: Channel -> ExchangeName -> IO ()
createCronExchange chan cronExchangeName = declareExchange chan $ newExchange {exchangeName = cronExchangeName, exchangeType = "direct"}


sendCronMessage :: Channel -> ExchangeName -> Text -> IO (Maybe Int)
sendCronMessage chan exchangeName cronEvent = publishMsg chan exchangeName cronEvent $ newMsg {msgBody = "test-message"}


testCallBack :: (Message, Envelope) -> IO ()
testCallBack (msg, env) = do
  putStr $ "received a message: " ++ (BL.unpack $ msgBody msg)
  ackEnv env

someFunc :: IO ()
someFunc = do
  conn <- openConnection "127.0.0.1" "/" "guest" "guest"
  chan <- openChannel conn
  let en = "cron.exchange"
  createCronExchange chan en 
  declareQueue chan newQueue {queueName = "test.cron.queue"}

  bindQueue chan "test.cron.queue" en "cron.min.1"

  consumeMsgs chan "test.cron.queue" Ack testCallBack
  
  sendCronMessage chan en "cron.min.1" 
  getLine
  closeConnection conn
  putStrLn "connection closed"
