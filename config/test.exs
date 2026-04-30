import Config

alias Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning

config :patterns, Patterns.Test.Repo,
  database: Path.expand("patterns_test.db", __DIR__),
  pool_size: 5,
  pool: Sandbox,
  timeout: 30_000,
  ownership_timeout: 30_000,
  default_transaction_mode: :immediate
