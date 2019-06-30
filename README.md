# pidgeon

## Description ##

This is a scheduler manager that uses RabbitMQ to send messages to a direct exchange with a routing key containing when a scheduled job should run.
It also uses Consul for HA deployments so that you can run this on more than one machine and it can continue running. Basically, it uses Consul for leader election.

To schedule the messages it uses the crontab format.

Checkout the [sample config file](sample/config.toml) for how it's configured.


## Rough overview ##

If you run this application and have something scheduled to run every 30 minutes in the crontab format with a routing key of "cron.minute.30" then any application that wants to run 
any job every 30 minutes just has to bind to the exchange specified in the config file using "cron.minute.30" as a routing key.

This makes it easy to schedule jobs in a variety of languages/apps since the only thing you would need is a RabbitMQ library.

## Why ##
This is probably not the best code, but my Haskell was rusty and I needed something to code as a learning exercise.

I also wanted to mess with Consul as well.
