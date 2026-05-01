defmodule Patterns.Memo do
  @moduledoc """
  Function memoization backed by `Patterns.Proxy`.

  Use `Patterns.Memo` in a module, then annotate functions with `@memo`:

      defmodule Blog.Posts do
        use Patterns.Memo

        @memo ttl: :timer.minutes(5)
        def fetch_post(id) do
          HTTP.get!("https://example.com/posts/\#{id}")
        end
      end

  Memoized functions cache by their argument list. Cached values are returned
  until their TTL expires or the backing proxy restarts.

  `@memo` applies to the next `def` or `defp`, using the same function/arity
  scoping as `Patterns.Middleware`. It composes with `@middleware`; middleware
  outside memoization still runs on cache hits, while middleware inside
  memoization only runs on misses. Use at most one `@memo` annotation per
  function; put all options in the same annotation.

  ## Options

  Options must be a keyword list. Annotation shape is validated at compile time;
  option values are validated when the memoized function is called.

  `:ttl` sets how long cached values stay fresh. It accepts a timeout in
  milliseconds or `:infinity`. The default is `:infinity`.

  `:dirty` controls cache writes. The default is `true`, which avoids
  serializing through the proxy process and lets concurrent misses overwrite each
  other. Set `dirty: false` when concurrent misses may duplicate work, but only
  one fresh cache value should win. Exceptions are not cached.

  `:proxy` chooses the `Patterns.Proxy.Supervisor` name. The default is
  `Patterns.Proxy.Supervisor`.

  ## Invalidation

  Use `invalidate/4` to clear the currently stored value for one memoized
  argument list. It does not cancel in-flight computations, so a racing call may
  publish a new cached value after invalidation returns. Pass the same `:proxy`
  used by `@memo` when a function uses a custom proxy supervisor.

  Inside a memoized function body, call `invalidate/0` to invalidate the current
  argument list for the currently running computation and skip caching the
  current result. Cache hits do not run the function body, so `invalidate/0` only
  runs when the memoized function is already computing.

  `use Patterns.Memo` imports `invalidate/0`. If your module already defines or
  imports an `invalidate/0`, exclude this import and use the explicit
  `invalidate/4` function instead.
  """

  @behaviour Patterns.Middleware

  import Patterns.Proxy.DSL, only: [with_proxy: 4]
  import Patterns.Utils, only: [ctx: 1, update_ctx: 2, with_ctx: 2]

  alias Patterns.Middleware
  alias Patterns.Middleware.Resolution
  alias Patterns.Proxy

  @default_opts [ttl: :infinity, dirty: true, proxy: Patterns.Proxy.Supervisor]
  @context_key :patterns_memo_context

  @typedoc """
  Memoization options.
  """
  @type options :: [ttl: timeout() | :infinity, dirty: boolean(), proxy: Proxy.supervisor()]

  @doc """
  Invalidates the current memoized function call.

  This macro is only available inside modules using `Patterns.Memo`. It must be
  called from the memoized function body itself. The current argument list is
  invalidated with the function's `@memo` proxy options, and the current result is
  not cached.
  """
  defmacro invalidate do
    case __CALLER__.function do
      {function, arity} ->
        quote do
          Patterns.Memo.__invalidate_current__(__MODULE__, unquote(function), unquote(arity))
        end

      nil ->
        raise ArgumentError, "invalidate/0 can only be called inside a function"
    end
  end

  @doc """
  Invalidates the cached value for `module.function(args)`.

  `args` must be the exact argument list seen by `Patterns.Memo`. The cache
  scope is `{module, function, length(args)}`.

  Accepts `:proxy` and `:dirty` options with the same validation as `@memo`.
  The default proxy is `Patterns.Proxy.Supervisor`, and deletes are coordinated
  by default with `dirty: false`. Returns `{:error, :not_started}` if the proxy
  supervisor is not running. In-flight computations are not cancelled and may
  publish a new cached value after invalidation returns.
  """
  @spec invalidate(module(), atom(), [term()], keyword()) :: :ok | {:error, term()}
  def invalidate(module, function, args, opts \\ []) when is_atom(module) and is_atom(function) and is_list(args) do
    opts = Keyword.merge([ttl: :infinity, dirty: false, proxy: Patterns.Proxy.Supervisor], opts)
    :ok = validate_opts!(opts)

    scope = {module, function, length(args)}

    with {:ok, proxy} <- Proxy.ensure(opts[:proxy], scope) do
      Proxy.update(proxy, {:args, args}, :missing, &invalidate_entry/1, dirty: opts[:dirty])
      :ok
    end
  end

  @doc false
  def __invalidate_current__(module, function, arity) when is_atom(module) and is_atom(function) do
    context = ctx(@context_key)

    if is_nil(context) or context.module != module or context.function != function or context.arity != arity do
      raise RuntimeError, "invalidate/0 can only be called inside the matching memoized function body"
    end

    update_ctx(@context_key, fn context -> %{context | invalidated?: true} end)
    invalidate(module, function, context.args, proxy: context.proxy, dirty: context.dirty)
  end

  @doc """
  Sets up `@memo` annotations for the using module.
  """
  defmacro __using__(_opts) do
    quote do
      use Patterns.Middleware

      import unquote(__MODULE__), only: [invalidate: 0]

      Module.register_attribute(__MODULE__, :memo, accumulate: true)
      @on_definition {unquote(__MODULE__), :__on_definition__}
    end
  end

  @doc false
  def __on_definition__(env, kind, _name, _args, _guards, _body) when kind in [:def, :defp] do
    memo = Module.get_attribute(env.module, :memo)
    opts = memo_opts!(memo)

    Module.delete_attribute(env.module, :memo)

    if !is_nil(opts) do
      Module.put_attribute(env.module, :middleware, {__MODULE__, opts})
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body) do
    :ok
  end

  @impl Middleware
  def process(args, %Resolution{} = resolution) when is_list(args) do
    opts = Keyword.merge(@default_opts, resolution.opts)
    :ok = validate_opts!(opts)

    proxy_supervisor = Keyword.fetch!(opts, :proxy)

    opts = Keyword.put(opts, :key, {:args, args})
    scope = {resolution.module, resolution.function, resolution.arity}

    with_proxy proxy_supervisor, scope, [] do
      proxy -> handle_memo(proxy, args, resolution, opts)
    end
  end

  defp handle_memo(proxy, args, resolution, opts) do
    with {:ok, {:value, value, expires_at}} <- Proxy.get(proxy, opts[:key]),
         true <- fresh?(expires_at) do
      {value, resolution}
    else
      _miss_or_stale -> refresh_cache(proxy, args, resolution, opts)
    end
  end

  defp refresh_cache(proxy, args, resolution, opts) do
    context = %{
      id: make_ref(),
      module: resolution.module,
      function: resolution.function,
      arity: resolution.arity,
      args: args,
      invalidated?: false,
      dirty: Keyword.fetch!(opts, :dirty),
      proxy: Keyword.fetch!(opts, :proxy)
    }

    {{value, resolution}, context} =
      with_ctx patterns_memo_context: context do
        Middleware.yield(args, resolution)
      end

    cond do
      context.patterns_memo_context.invalidated? ->
        {value, resolution}

      opts[:dirty] ->
        :ok = Proxy.put(proxy, opts[:key], {:value, value, expires_at(opts[:ttl])}, dirty: true)
        {value, resolution}

      true ->
        {:value, winner, _expires_at} =
          Proxy.update(proxy, opts[:key], :missing, &refresh_entry(&1, value, opts[:ttl]), dirty: false)

        {winner, resolution}
    end
  end

  defp refresh_entry({:value, _value, expires_at} = entry, value, ttl) do
    if fresh?(expires_at) do
      entry
    else
      {:value, value, expires_at(ttl)}
    end
  end

  defp refresh_entry(_missing_or_stale, value, ttl) do
    {:value, value, expires_at(ttl)}
  end

  defp invalidate_entry({:value, _value, _expires_at}) do
    :missing
  end

  defp invalidate_entry(entry) do
    entry
  end

  defp fresh?(:infinity) do
    true
  end

  defp fresh?(expires_at) do
    System.monotonic_time(:millisecond) < expires_at
  end

  defp expires_at(:infinity) do
    :infinity
  end

  defp expires_at(ttl) do
    System.monotonic_time(:millisecond) + ttl
  end

  defp memo_opts!([]) do
    nil
  end

  defp memo_opts!([opts]) when is_list(opts) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError, "expected @memo options to be a keyword list, got: #{inspect(opts)}"
    end

    opts
  end

  defp memo_opts!([opts]) do
    raise ArgumentError, "expected @memo options to be a keyword list, got: #{inspect(opts)}"
  end

  defp memo_opts!(_opts) do
    raise ArgumentError, "expected at most one @memo annotation per function; put all options in one @memo"
  end

  defp validate_opts!(opts) do
    ttl = Keyword.fetch!(opts, :ttl)
    dirty? = Keyword.fetch!(opts, :dirty)
    proxy = Keyword.fetch!(opts, :proxy)

    if ttl != :infinity and not (is_integer(ttl) and ttl >= 0) do
      raise ArgumentError, "expected :ttl to be a non-negative integer or :infinity, got: #{inspect(ttl)}"
    end

    if !is_boolean(dirty?) do
      raise ArgumentError, "expected :dirty to be a boolean, got: #{inspect(dirty?)}"
    end

    if !is_atom(proxy) do
      raise ArgumentError, "expected :proxy to be an atom, got: #{inspect(proxy)}"
    end

    :ok
  end
end
