defmodule Patterns.Proxy do
  @moduledoc """
  Low-level runtime state for building proxy patterns.

  `Patterns.Proxy` is the small runtime primitive underneath higher-level tools
  like memoization, throttling, and debouncing. You can also use it directly when
  you want to build your own function wrapper or annotation on top of supervised
  state.

  Use `with_proxy/4` to lazily start the proxy for a scope, then use `get/3`,
  `put/4`, `update/5`, and `delete/3` to work with its state. The scope chooses
  the proxy process and its state; keys choose values inside that state.

  > #### Proxy handles are ephemeral {: .info}
  >
  > Proxies are optimized for use inside `with_proxy/4`. Callers may use
  > `ensure/3` directly, but cached proxies are not guaranteed to survive proxy
  > restarts or storage implementation changes. Reads and dirty operations use
  > the opaque handle directly. Non-dirty writes, updates, and deletes re-resolve
  > the current proxy process before running.

  > #### The current backend is ETS {: .info}
  >
  > Each proxy currently owns one ETS table, but callers should treat that as an
  > implementation detail. Future versions may support other proxy backends.

  Reads avoid serializing through the proxy process. Dirty writes also avoid the
  proxy process. Non-dirty writes, updates, and deletes are coordinated through
  the proxy process.

  Proxy state is volatile. If a proxy process crashes or restarts, its current
  state is lost.

  Dirty updates are read-modify-write operations in the caller process. They are
  fast, but concurrent dirty updates can overwrite each other.

  > #### Dirty operations trade correctness for speed {: .warning}
  >
  > Dirty writes avoid serializing through the proxy process, so they can be
  > faster under load. Under high contention they may race with other callers,
  > including non-dirty callers. Use non-dirty operations consistently when all
  > callers must agree on the exact state change.
  """

  use GenServer

  alias __MODULE__
  alias Patterns.Proxy.Supervisor, as: ProxySupervisor
  alias Patterns.Utils.ETS

  defstruct [:scope, :handle]

  @typedoc """
  Identifies one proxy process and its state.

  Higher-level patterns usually use `{module, function, arity}` as the scope.
  """
  @type scope :: term()

  @typedoc """
  Identifies one value inside a proxy scope.

  Higher-level patterns usually use function arguments as part of the key.
  """
  @type key :: term()

  @typedoc """
  Ephemeral handle for a lazily started proxy.
  """
  @opaque handle :: map()
  @type proxy :: %Proxy{scope: scope(), handle: handle()}

  @typedoc """
  Registered `Patterns.Proxy.Supervisor` name.
  """
  @type supervisor :: atom()

  @typedoc """
  Proxy startup options.

  Currently reserved for future use.
  """
  @type start_options :: keyword()

  @typedoc """
  Proxy operation options.

  `dirty: true` avoids serializing writes, updates, and deletes through the
  proxy process. It is accepted but ignored by `get/3`.
  """
  @type options :: [dirty: boolean()]

  @doc """
  Imports block syntax for `with_proxy`.

      use Patterns.Proxy

      with_proxy Patterns.Proxy.Supervisor, scope, [] do
        proxy ->
          Patterns.Proxy.get(proxy, :post)
      end
  """
  defmacro __using__(_opts) do
    quote do
      import Patterns.Proxy.DSL, only: [with_proxy: 3, with_proxy: 4]
    end
  end

  @doc """
  Finds or starts the proxy for `scope` under `supervisor`.

  The supervisor must already be running. See `Patterns.Proxy.Supervisor` for
  the default supervision setup.

  `opts` is currently reserved for future proxy startup options.
  """
  @spec ensure(supervisor(), scope(), start_options()) :: {:ok, proxy()} | {:error, term()}
  def ensure(supervisor, scope, opts \\ []) when is_atom(supervisor) and is_list(opts) do
    registry = ProxySupervisor.registry(supervisor)

    case Registry.lookup(registry, scope) do
      [{pid, table}] ->
        {:ok, proxy(scope, registry, pid, table)}

      [] ->
        supervisor
        |> ProxySupervisor.child_supervisor()
        |> DynamicSupervisor.start_child({Proxy, Keyword.merge(opts, scope: scope, registry: registry)})
        |> case do
          {:ok, pid} ->
            {:ok, proxy(scope, registry, pid)}

          {:error, {:already_started, pid}} ->
            {:ok, proxy(scope, registry, pid)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    ArgumentError ->
      {:error, :not_started}
  catch
    :exit, {:noproc, _reason} ->
      {:error, :not_started}
  end

  @doc """
  Finds or starts the proxy for `scope` under `supervisor`.

  Raises when the proxy cannot be started.

  `opts` is currently reserved for future proxy startup options.
  """
  @spec ensure!(supervisor(), scope(), start_options()) :: proxy()
  def ensure!(supervisor, scope, opts \\ []) do
    case ensure(supervisor, scope, opts) do
      {:ok, proxy} ->
        proxy

      {:error, reason} ->
        raise RuntimeError, "could not start proxy #{inspect(scope)}: #{inspect(reason)}"
    end
  end

  defp proxy(scope, registry, pid, table \\ nil) do
    %Proxy{scope: scope, handle: %{registry: registry, pid: pid, table: table || GenServer.call(pid, :table)}}
  end

  @doc """
  Finds or starts a proxy, then calls `fun` with it.

  This is the preferred API for working with proxies. The proxy handle passed to
  `fun` is optimized for use during that call and should not be treated as a
  durable resource. `fun` runs in the caller process.

  `opts` is currently reserved for future proxy startup options.

  ## Example

      scope = {Blog.Posts, :fetch_post, 1}
      key = {:args, [post_id]}

      Patterns.Proxy.with_proxy(Patterns.Proxy.Supervisor, scope, [], fn proxy ->
        case Patterns.Proxy.get(proxy, key) do
          {:ok, post} ->
            post

          :error ->
            post = fetch_post(post_id)
            :ok = Patterns.Proxy.put(proxy, key, post)
            post
        end
      end)
  """
  @spec with_proxy(supervisor(), scope(), start_options(), (proxy() -> result)) :: result when result: term()
  def with_proxy(supervisor, scope, opts \\ [], fun) when is_function(fun, 1) and is_list(opts) do
    proxy = ensure!(supervisor, scope, opts)

    fun.(proxy)
  end

  @doc """
  Reads a value from the proxy state.

  Reads avoid serializing through the proxy process. `dirty: true` is accepted for
  symmetry with the write APIs, but is currently ignored. Reads use the opaque
  handle directly, so stale proxies may raise after proxy restarts.

  ## Example

      Patterns.Proxy.get(proxy, {:args, [post_id]})
      #=> {:ok, post}

      Patterns.Proxy.get(proxy, :missing)
      #=> :error
  """
  @spec get(proxy(), key(), options()) :: {:ok, term()} | :error
  def get(%Proxy{} = proxy, key, opts \\ []) when is_list(opts) do
    {_pid, table} = resolve!(proxy, dirty?: true)

    ETS.fetch(table, key)
  end

  @doc """
  Writes a value to the proxy state.

  By default writes are coordinated through the proxy process. Pass
  `dirty: true` to avoid serializing through the proxy process. Dirty writes use
  the opaque handle directly, so stale proxies may raise after proxy restarts.
  """
  @spec put(proxy(), key(), term(), options()) :: :ok
  def put(%Proxy{} = proxy, key, value, opts \\ []) when is_list(opts) do
    dirty? = Keyword.get(opts, :dirty, false)
    {pid, table} = resolve!(proxy, dirty?: dirty?)

    if dirty? do
      ETS.put(table, key, value)
      :ok
    else
      GenServer.call(pid, {:put, key, value})
    end
  end

  @doc """
  Updates a value in the proxy state and returns the new value.

  By default updates are coordinated through the proxy process and `fun` runs
  inside the proxy process. Keep `fun` quick and side-effect-light. Slow
  functions block that proxy, and `fun` must not call non-dirty operations on the
  same proxy. If `fun` raises, the caller exits and the proxy process crashes,
  losing its volatile state.

  Pass `dirty: true` to perform the read-modify-write in the caller process.
  Dirty updates use the opaque handle directly, so stale proxies may raise after
  proxy restarts. They are fast, but concurrent dirty updates can overwrite each
  other.
  """
  @spec update(proxy(), key(), term(), (term() -> term()), options()) :: term()
  def update(%Proxy{} = proxy, key, initial, fun, opts \\ []) when is_function(fun, 1) and is_list(opts) do
    dirty? = Keyword.get(opts, :dirty, false)
    {pid, table} = resolve!(proxy, dirty?: dirty?)

    if dirty? do
      value = table |> ETS.get(key, initial) |> fun.()
      ETS.put(table, key, value)

      value
    else
      GenServer.call(pid, {:update, key, initial, fun})
    end
  end

  @doc """
  Deletes a value from the proxy state.

  By default deletes are coordinated through the proxy process. Pass
  `dirty: true` to avoid serializing through the proxy process. Dirty deletes
  use the opaque handle directly, so stale proxies may raise after proxy
  restarts.
  """
  @spec delete(proxy(), key(), options()) :: :ok
  def delete(%Proxy{} = proxy, key, opts \\ []) when is_list(opts) do
    dirty? = Keyword.get(opts, :dirty, false)
    {pid, table} = resolve!(proxy, dirty?: dirty?)

    if dirty? do
      ETS.delete(table, key)

      :ok
    else
      GenServer.call(pid, {:delete, key})
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    registry = Keyword.fetch!(opts, :registry)
    scope = Keyword.fetch!(opts, :scope)

    GenServer.start_link(Proxy, opts, name: {:via, Registry, {registry, scope}})
  end

  @impl GenServer
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    scope = Keyword.fetch!(opts, :scope)
    table = ETS.new(access: :public, read_concurrency: true, write_concurrency: true)
    Registry.update_value(registry, scope, fn _value -> table end)

    {:ok, %{scope: scope, table: table}}
  end

  @impl GenServer
  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    ETS.put(state.table, key, value)

    {:reply, :ok, state}
  end

  def handle_call({:update, key, initial, fun}, _from, state) do
    value = state.table |> ETS.get(key, initial) |> fun.()
    ETS.put(state.table, key, value)

    {:reply, value, state}
  end

  def handle_call({:delete, key}, _from, state) do
    ETS.delete(state.table, key)

    {:reply, :ok, state}
  end

  # NOTE: when `dirty?: true`, just use pid and table from proxy handle
  #       which is fast, cheap, but maybe stale for restarts.
  defp resolve!(%Proxy{} = proxy, dirty?: true) do
    {proxy.handle.pid, proxy.handle.table}
  end

  # NOTE: when `dirty?: false`, always look up the pid and table which is
  #       more expensive but much more robust.
  defp resolve!(%Proxy{} = proxy, dirty?: false) do
    case Registry.lookup(proxy.handle.registry, proxy.scope) do
      [{pid, table}] when is_reference(table) ->
        {pid, table}

      [{pid, _value}] ->
        {pid, GenServer.call(pid, :table)}

      [] ->
        raise RuntimeError, "proxy #{inspect(proxy.scope)} is not running"
    end
  end
end
