if Mix.env() == :test do
  defmodule Patterns.Test.Repo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :patterns,
      adapter: Ecto.Adapters.SQLite3
  end
end
