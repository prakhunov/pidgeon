{-# LANGUAGE OverloadedStrings    #-}

module Config
  ( readConfig,
    CronConfig (..),
    RabbitServer (..),
    RabbitConfig (..),
    PidgeonConfig (..),
    ConsulConfig (..),
    ExchangeName
  ) where

import Data.Text (Text)
import Data.Eq (Eq)
import Toml (TomlCodec, (.=))
import Network.Socket (PortNumber)
import qualified Toml

type ExchangeName = Text


data ConsulConfig = ConsulConfig
  { consulLockName :: Text,
    consulHost :: Text,
    consulHttpPort :: PortNumber,
    consulTls :: Bool
  } deriving (Show)

data RabbitServer = RabbitServer
  { host :: Text,
    port :: Maybe PortNumber
  } deriving (Show, Eq)

data RabbitConfig = RabbitConfig
  { virtualHost :: Text,
    username :: Text,
    password :: Text,
    connectionName :: Maybe Text,
    exchangeName :: ExchangeName,
    rabbitTls :: Bool,
    servers :: [RabbitServer]
  } deriving (Show)

data CronConfig = CronConfig
  { forceUniqueTimes :: Maybe Bool,
    schedules :: [Text],
    newConnectionTimeout :: Int
  } deriving (Show)

data PidgeonConfig = PidgeonConfig
  { rabbit :: RabbitConfig,
    cron :: CronConfig,
    consul :: ConsulConfig
  } deriving (Show)


consulConfigCodec :: TomlCodec ConsulConfig
consulConfigCodec = ConsulConfig
  <$> Toml.text "lockName" .= consulLockName
  <*> Toml.text "host" .= consulHost
  <*> portNumberCodec "httpPort" .= consulHttpPort
  <*> Toml.bool "tls" .= consulTls


fromIntegralWord16 :: (Integral a, Num b) => a -> b
fromIntegralWord16 a
  | a > 65535 || a <= 0 = error "Port Number must be between 1 and 65535"
  | otherwise = fromIntegral a

portNumberCodec :: Toml.Key -> TomlCodec PortNumber
portNumberCodec k = Toml.dimap fromIntegralWord16 fromIntegralWord16 $ Toml.int k

cronConfigCodec :: TomlCodec CronConfig
cronConfigCodec = CronConfig
  <$> Toml.dioptional (Toml.bool "forceUniqueTimes") .= forceUniqueTimes
  <*> Toml.arrayOf Toml._Text "schedules" .= schedules
  <*> Toml.int "newConnectionTimeout" .= newConnectionTimeout


rabbitServerCodec :: TomlCodec RabbitServer
rabbitServerCodec = RabbitServer
  <$> Toml.text "host" .= host
  <*> Toml.dioptional (portNumberCodec "port") .= port


rabbitConfigCodec :: TomlCodec RabbitConfig
rabbitConfigCodec = RabbitConfig
  <$> Toml.text "virtualHost" .= virtualHost
  <*> Toml.text "username" .= username
  <*> Toml.text "password" .= password
  <*> Toml.dioptional (Toml.text "connectionName") .= connectionName
  <*> Toml.text "exchangeName" .= exchangeName
  <*> Toml.bool "tls" .= rabbitTls
  <*> Toml.list rabbitServerCodec "servers" .= servers

pidgeonConfigCodec :: TomlCodec PidgeonConfig
pidgeonConfigCodec = PidgeonConfig
  <$> Toml.table rabbitConfigCodec "rabbit" .= rabbit
  <*> Toml.table cronConfigCodec "cron" .= cron
  <*> Toml.table consulConfigCodec "consul" .= consul

readConfig :: FilePath -> IO PidgeonConfig
readConfig = Toml.decodeFile pidgeonConfigCodec
