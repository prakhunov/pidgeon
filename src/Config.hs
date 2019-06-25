{-# LANGUAGE OverloadedStrings    #-}

module Config
  ( readConfig,
    CronConfig (..),
    RabbitServer (..),
    RabbitConfig (..),
    PidgeonConfig (..),
    ExchangeName
  ) where

import Data.Text (Text)
import Data.Eq (Eq)
import Toml (TomlCodec, (.=))
import Network.Socket (PortNumber)
import qualified Toml

type ExchangeName = Text

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


fromIntegralWord16 :: (Integral a, Num b) => a -> b
fromIntegralWord16 a
  | a > 65535 || a <= 0 = error "Port Number must be between 1 and 65535"
  | otherwise = fromIntegral a

portNumberCodec :: TomlCodec PortNumber
portNumberCodec = Toml.dimap fromIntegralWord16 fromIntegralWord16 $ Toml.int "port"

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
