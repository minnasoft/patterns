defmodule Patterns.Utils.ETS do
  @moduledoc """
  Map-shaped helpers for mutable ETS tables.

  ETS stores entries as tuples and exposes Erlang-shaped return values. This
  module wraps common key/value operations in a tiny API that feels close to
  `Map` for `:set` and `:ordered_set` tables, while still operating on mutable
  ETS tables and exposing bag-style behavior where ETS does.

  Tables created with `new/0`, `new/1`, or `new/2` are owned by the calling
  process and disappear when that process exits, unless you configure an ETS
  heir. Avoid creating tables in short-lived processes unless ownership is
  deliberate.

  ## Bag Semantics

  For `:bag` and `:duplicate_bag` tables, `fetch/2` and `get/3` return lists of
  values. `put/3` inserts values instead of replacing the key. `:bag` tables
  deduplicate identical `{key, value}` pairs, while `:duplicate_bag` tables
  preserve them. `delete/2` removes all values for a key.

  ## Example

      alias Patterns.Utils.ETS

      table = ETS.new(%{count: 1}, access: :public)

      ETS.fetch(table, :count)
      #=> {:ok, 1}

      ETS.get(table, :missing, :default)
      #=> :default

      ETS.update(table, :count, 0, &(&1 + 1))
      #=> table

      ETS.to_list(table)
      #=> [count: 2]

  `update/4` performs a read-modify-write operation in the caller process. It is
  intentionally lightweight and does not serialize concurrent updates. It only
  supports `:set` and `:ordered_set` tables.
  """

  @table_types [:set, :ordered_set, :bag, :duplicate_bag]
  @access_modes [:public, :protected, :private]

  @typedoc """
  ETS table type.
  """
  @type type :: :set | :ordered_set | :bag | :duplicate_bag

  @typedoc """
  ETS table access mode.
  """
  @type access :: :public | :protected | :private

  @typedoc """
  ETS table identifier.
  """
  @type table :: :ets.table()

  @typedoc """
  Options accepted by `new/2`.
  """
  @type option ::
          {:name, atom()}
          | {:type, type()}
          | {:access, access()}
          | {:named_table, boolean()}
          | {:heir, :none | {pid(), term()}}
          | {:read_concurrency, boolean()}
          | {:write_concurrency, boolean() | :auto}
          | {:decentralized_counters, boolean()}
          | {:compressed, boolean()}

  @doc """
  Creates an empty ETS table.

  See `new/1` for options and table ownership details.
  """
  @spec new() :: table()
  def new do
    new([], [])
  end

  @doc """
  Creates an ETS table from options or enumerable data.

  Tables are owned by the calling process.

  Enumerable data must yield `{key, value}` pairs. This module always stores keys in
  tuple position 1 and values in tuple position 2. Options are translated to
  `:ets.new/2` options with keyword names that read like normal Elixir options.

  With one list argument, `new/1` treats the list as options. Use `new/2` when
  inserting a list of pairs. Non-list arguments to `new/1` are treated as
  enumerable data.

  ## Options

  `:name` sets the atom passed as the table name to `:ets.new/2`. The default is
  `Patterns.Utils.ETS`. For anonymous tables, this name is metadata; it is only
  globally registered when `named_table: true` is set.

  `:type` maps to the ETS table type and may be `:set`, `:ordered_set`, `:bag`,
  or `:duplicate_bag`. The default is `:set`.

  `:access` maps to the ETS protection mode and may be `:public`, `:protected`,
  or `:private`. The default is `:protected`.

  `:named_table` maps to the ETS `:named_table` option. When true, the table is
  registered under `:name` and `new/2` returns that name.

  `:heir` maps to the ETS heir option and accepts `:none` or `{pid, data}`.

  `:read_concurrency`, `:decentralized_counters`, and `:compressed` accept
  booleans and map to the matching ETS options.

  `:write_concurrency` accepts a boolean or `:auto` and maps to the matching ETS
  option.

  ## Example

      alias Patterns.Utils.ETS

      table = ETS.new([{:count, 1}], type: :set, access: :public)

      ETS.get(table, :count)
      #=> 1
  """
  @spec new([option()] | Enumerable.t()) :: table()
  def new(opts) when is_list(opts) do
    new([], opts)
  end

  def new(enumerable) do
    new(enumerable, [])
  end

  @doc """
  Creates an ETS table, inserts `enumerable`, and applies `opts`.

  Use this arity when inserting a list of pairs. See `new/1` for options and
  table ownership details.
  """
  @spec new(Enumerable.t(), [option()]) :: table()
  def new(enumerable, opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if !is_atom(name) do
      raise ArgumentError, "invalid ETS option :name, expected an atom, got: #{inspect(name)}"
    end

    opts =
      opts
      |> Keyword.put_new(:type, :set)
      |> Keyword.put_new(:access, :protected)
      |> Enum.reduce([], fn option, acc ->
        case parse_opt!(option) do
          nil -> acc
          option -> [option | acc]
        end
      end)

    entries =
      Enum.map(enumerable, fn
        {key, value} ->
          {key, value}

        entry ->
          raise ArgumentError, "expected enumerable of {key, value} pairs, got: #{inspect(entry)}"
      end)

    table = :ets.new(name, Enum.reverse(opts))

    if entries != [] do
      true = :ets.insert(table, entries)
    end

    table
  end

  @doc """
  Fetches a value from `table`.

  Returns `{:ok, value}` when `key` exists and `:error` otherwise. For `:bag`
  and `:duplicate_bag` tables, returns `{:ok, values}` where `values` is the list
  of values for `key`.
  """
  @spec fetch(table(), term()) :: {:ok, term() | [term()]} | :error
  def fetch(table, key) do
    case :ets.lookup(table, key) do
      [] ->
        :error

      entries ->
        case :ets.info(table, :type) do
          type when type in [:set, :ordered_set] ->
            [{_key, value}] = entries

            {:ok, value}

          type when type in [:bag, :duplicate_bag] ->
            {:ok, Enum.map(entries, fn {_key, value} -> value end)}
        end
    end
  end

  @doc """
  Gets a value from `table`, returning `default` when `key` is missing.

  The default is `nil`, matching `Map.get/3`. For `:bag` and `:duplicate_bag`
  tables, returns the list of values for `key`.
  """
  @spec get(table(), term(), term()) :: term()
  def get(table, key, default \\ nil) do
    case fetch(table, key) do
      {:ok, value} ->
        value

      :error ->
        default
    end
  end

  @doc """
  Stores `value` under `key` in `table`.

  Returns `table` when the write succeeds. For `:set` and `:ordered_set` tables,
  `put/3` replaces the value for `key`. For `:bag` tables, values are inserted
  and identical `{key, value}` pairs are deduplicated by ETS. For
  `:duplicate_bag` tables, duplicate pairs are preserved.
  """
  @spec put(table(), term(), term()) :: table()
  def put(table, key, value) do
    true = :ets.insert(table, {key, value})

    table
  end

  @doc """
  Updates `key` in `table` and returns `table`.

  When `key` is missing, `initial` is passed to `fun`. Only `:set` and
  `:ordered_set` tables are supported.
  """
  @spec update(table(), term(), term(), (term() -> term())) :: table()
  def update(table, key, initial, fun) when is_function(fun, 1) do
    if !(set?(table) or ordered_set?(table)) do
      raise ArgumentError, "ETS.update/4 only supports :set and :ordered_set tables"
    end

    value = table |> get(key, initial) |> fun.()
    put(table, key, value)
  end

  @doc """
  Deletes `key` from `table`.

  Returns `table`, including when `key` was already missing. For bag-style
  tables, all values for `key` are deleted.
  """
  @spec delete(table(), term()) :: table()
  def delete(table, key) do
    true = :ets.delete(table, key)

    table
  end

  @doc """
  Returns all entries from `table` as a list.

  Entry order follows ETS and is not guaranteed for unordered table types. For
  bag-style tables, the returned list may include multiple entries for the same
  key.
  """
  @spec to_list(table()) :: [{term(), term()}]
  def to_list(table) do
    :ets.tab2list(table)
  end

  @doc """
  Returns true when `table` is a `:set` table.
  """
  @spec set?(table()) :: boolean()
  def set?(table) do
    :ets.info(table, :type) == :set
  end

  @doc """
  Returns true when `table` is an `:ordered_set` table.
  """
  @spec ordered_set?(table()) :: boolean()
  def ordered_set?(table) do
    :ets.info(table, :type) == :ordered_set
  end

  @doc """
  Returns true when `table` is a `:bag` table.
  """
  @spec bag?(table()) :: boolean()
  def bag?(table) do
    :ets.info(table, :type) == :bag
  end

  @doc """
  Returns true when `table` is a `:duplicate_bag` table.
  """
  @spec duplicate_bag?(table()) :: boolean()
  def duplicate_bag?(table) do
    :ets.info(table, :type) == :duplicate_bag
  end

  # NOTE: we want to let user's pass in Elixir style keyword options
  #       and if we're going to translate them to ETS options, we might as well validate them
  #       and raise for better DX
  defp parse_opt!({:heir, :none}) do
    {:heir, :none}
  end

  defp parse_opt!({:type, type}) when type in @table_types do
    type
  end

  defp parse_opt!({:type, _value}) do
    raise ArgumentError, "invalid ETS option :type"
  end

  defp parse_opt!({:access, access}) when access in @access_modes do
    access
  end

  defp parse_opt!({:access, _value}) do
    raise ArgumentError, "invalid ETS option :access"
  end

  defp parse_opt!({:heir, {pid, data}}) when is_pid(pid) do
    {:heir, pid, data}
  end

  defp parse_opt!({:heir, _value}) do
    raise ArgumentError, "invalid ETS option :heir"
  end

  defp parse_opt!({:read_concurrency, read_concurrency?}) when is_boolean(read_concurrency?) do
    {:read_concurrency, read_concurrency?}
  end

  defp parse_opt!({:read_concurrency, _value}) do
    raise ArgumentError, "invalid ETS option :read_concurrency"
  end

  defp parse_opt!({:write_concurrency, write_concurrency})
       when is_boolean(write_concurrency) or write_concurrency == :auto do
    {:write_concurrency, write_concurrency}
  end

  defp parse_opt!({:write_concurrency, _value}) do
    raise ArgumentError, "invalid ETS option :write_concurrency"
  end

  defp parse_opt!({:decentralized_counters, decentralized_counters?}) when is_boolean(decentralized_counters?) do
    {:decentralized_counters, decentralized_counters?}
  end

  defp parse_opt!({:decentralized_counters, _value}) do
    raise ArgumentError, "invalid ETS option :decentralized_counters"
  end

  defp parse_opt!({:named_table, true}) do
    :named_table
  end

  defp parse_opt!({:named_table, false}) do
    nil
  end

  defp parse_opt!({:named_table, _value}) do
    raise ArgumentError, "invalid ETS option :named_table"
  end

  defp parse_opt!({:compressed, true}) do
    :compressed
  end

  defp parse_opt!({:compressed, false}) do
    nil
  end

  defp parse_opt!({:compressed, _value}) do
    raise ArgumentError, "invalid ETS option :compressed"
  end

  defp parse_opt!({key, _value}) do
    raise ArgumentError, "unknown ETS option #{inspect(key)}"
  end

  defp parse_opt!(option) do
    raise ArgumentError, "invalid ETS option #{inspect(option)}"
  end
end
