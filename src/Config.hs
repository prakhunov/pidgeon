{-# OPTIONS -Wno-unused-top-binds #-}
{-# LANGUAGE OverloadedStrings    #-}

module Config
  ( readConfig
  ) where

import Data.Text (Text)
import Data.Eq (Eq)
import Toml (TomlCodec, (.=))
import Network.Socket (PortNumber)

import qualified Toml

data RabbitServer = RabbitServer
  { host :: Text,
    port :: Maybe PortNumber
  } deriving (Show, Eq)

data RabbitConfig = RabbitConfig
  { virtualHost :: Text,
    username :: Text,
    password :: Text,
    connectionName :: Maybe Text,
    exchangeName :: Text,
    servers :: [RabbitServer]
  } deriving (Show)

data CronConfig = CronConfig
  { forceUniqueTimes :: Maybe Bool,
    schedules :: [Text]
  } deriving (Show)

data PidgeonConfig = PidgeonConfig
  { rabbit :: RabbitConfig,
    cron :: CronConfig
  } deriving (Show)

portNumberCodec :: TomlCodec PortNumber
portNumberCodec = Toml.dimap fromIntegral fromIntegral $ Toml.int "port"

cronConfigCodec :: TomlCodec CronConfig
cronConfigCodec = CronConfig
  <$> Toml.dioptional (Toml.bool "forceUniqueTimes") .= forceUniqueTimes
  <*> Toml.arrayOf Toml._Text "schedules" .= schedules


rabbitServerCodec :: TomlCodec RabbitServer
rabbitServerCodec = RabbitServer
  <$> Toml.text "host" .= host
  <*> Toml.dioptional (portNumberCodec) .= port


rabbitConfigCodec :: TomlCodec RabbitConfig
rabbitConfigCodec = RabbitConfig
  <$> Toml.text "virtualHost" .= virtualHost
  <*> Toml.text "username" .= username
  <*> Toml.text "password" .= password
  <*> Toml.dioptional (Toml.text "connectionName") .= connectionName
  <*> Toml.text "exchangeName" .= exchangeName
  <*> Toml.list rabbitServerCodec "servers" .= servers


pidgeonConfigCodec :: TomlCodec PidgeonConfig
pidgeonConfigCodec = PidgeonConfig
  <$> Toml.table rabbitConfigCodec "rabbit" .= rabbit
  <*> Toml.table cronConfigCodec "cron" .= cron

readConfig :: FilePath -> IO (PidgeonConfig)
readConfig path = Toml.decodeFile pidgeonConfigCodec path
