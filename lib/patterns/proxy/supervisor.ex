defmodule Patterns.Proxy.Supervisor do
  @moduledoc """
  Supervisor for proxy processes.

  Add it to your application supervision tree:

      children = [
        Patterns.Proxy.Supervisor
      ]

  Or start a separate named supervisor:

      children = [
        {Patterns.Proxy.Supervisor, name: MyApp.ProxySupervisor}
      ]

  By default, the supervisor is registered as `Patterns.Proxy.Supervisor`. Pass
  an atom `:name` when you want to run a separate proxy supervisor, then pass
  that same name to `Patterns.Proxy.ensure/3` or `Patterns.Proxy.with_proxy/4`.

  Each proxy supervisor owns a registry and dynamic supervisor derived from its
  name, so `:via` and tuple names are not supported.

  Patterns does not start a global supervisor for you.
  """

  use Supervisor

  @doc """
  Starts a proxy supervisor.

  Starts with the name `Patterns.Proxy.Supervisor` unless an atom `:name` is
  provided.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc false
  @spec child_supervisor(atom()) :: atom()
  def child_supervisor(supervisor) when is_atom(supervisor) do
    Module.concat(supervisor, DynamicSupervisor)
  end

  @doc false
  @spec registry(atom()) :: atom()
  def registry(supervisor) when is_atom(supervisor) do
    Module.concat(supervisor, Registry)
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    children = [
      {Registry, keys: :unique, name: registry(name)},
      {DynamicSupervisor, name: child_supervisor(name), strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
