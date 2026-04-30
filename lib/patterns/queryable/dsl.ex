defmodule Patterns.Queryable.DSL do
  @moduledoc """
  Binding-aware query helpers for `Patterns.Queryable`.

  This module extends Ecto query composition with two small pieces:

  * `from/2`, which supports `binding/1` and `binding/2` source patterns.
  * Binding inspection helpers for resolving named bindings to indexes and
    schema modules.

  Most callers get `from/2` through `use Patterns.Queryable`. The binding
  inspection helpers are used by `Patterns.Queryable.Filters` to resolve nested
  association filters from the current scoped binding.
  """

  @doc """
  Extends `Ecto.Query.from/2` with binding-aware query source patterns.

  This macro otherwise delegates to Ecto's `from` DSL unchanged. It exists so
  modules using `Patterns.Queryable` can write queries against either the root
  binding or a binding supplied by surrounding query composition.

  Use `binding/1` to target the current scoped binding, falling back to the root
  query binding:

      from binding(entry) in query,
        where: entry.slug == ^slug

  Use `binding/2` to target an explicit named binding:

      from binding(:references, reference) in query,
        where: reference.target_slug == ^slug
  """
  defmacro from(expr, opts \\ []) do
    case expr do
      # NOTE: binding/1 targets the scoped named binding, or root position when unscoped.
      {:in, _meta, [{:binding, _binding_meta, [{name, meta, context}]}, query]} when is_atom(name) ->
        var = {name, meta, context}

        quote do
          if binding = Patterns.Utils.ctx(:binding) do
            Ecto.Query.from([{^binding, unquote(var)}] in unquote(query), unquote(opts))
          else
            Ecto.Query.from([unquote(var)] in unquote(query), unquote(opts))
          end
        end

      # NOTE: binding/2 always targets the explicit named binding supplied by the caller.
      {:in, _meta, [{:binding, _binding_meta, [binding_name, {name, meta, context}]}, query]}
      when is_atom(name) ->
        var = {name, meta, context}

        quote do
          Ecto.Query.from([{^unquote(binding_name), unquote(var)}] in unquote(query), unquote(opts))
        end

      # NOTE: Everything else is regular Ecto.Query.from/2 syntax.
      _other ->
        quote do
          Ecto.Query.from(unquote(expr), unquote(opts))
        end
    end
  end

  @doc """
  Returns the query binding index for a named binding.

      binding_index(from(post in Blog.Post, as: :post), :post)
      #=> 0

      binding_index(from(post in Blog.Post, as: :self), :self)
      #=> 0

  The unnamed root binding is index `0`, but it is not addressable as `:self`
  unless the query was explicitly created with `as: :self`.

      binding_index(from(post in Blog.Post), :self)
      # raises ArgumentError, "query binding :self does not exist"

      binding_index(from(post in Blog.Post), :missing)
      # raises ArgumentError, "query binding :missing does not exist"
  """
  def binding_index(%Ecto.Query{aliases: aliases}, binding) do
    Map.get(aliases, binding) || raise ArgumentError, "query binding #{inspect(binding)} does not exist"
  end

  @doc """
  Returns the Ecto schema module for the current scoped query binding.

      binding_schema(from post in Blog.Post)
      #=> Blog.Post

  Raises `ArgumentError` when the current binding does not resolve to an Ecto
  schema source.

      binding_schema(from post in "posts")
      # raises ArgumentError, "root query binding must be an Ecto schema source"
  """
  def binding_schema(%Ecto.Query{} = query) do
    :binding
    |> Patterns.Utils.ctx()
    |> then(&binding_schema(query, &1 || 0))
  end

  @doc """
  Returns the Ecto schema module for a named query binding or binding index.

      binding_schema(
        from(post in Blog.Post, join: comment in assoc(post, :comments), as: :comments),
        :comments
      )
      #=> Blog.Comment

      binding_schema(
        from(post in Blog.Post, join: comment in assoc(post, :comments), as: :comments),
        1
      )
      #=> Blog.Comment

  Raises `ArgumentError` when the binding does not exist or does not resolve to
  an Ecto schema source.

      binding_schema(from(post in Blog.Post), :missing)
      # raises ArgumentError, "query binding :missing does not exist"

      binding_schema(from(post in Blog.Post), 2)
      # raises ArgumentError, "query binding at index 2 does not exist"
  """
  def binding_schema(%Ecto.Query{} = query, binding) when is_atom(binding) do
    binding_schema(query, binding_index(query, binding))
  end

  def binding_schema(%Ecto.Query{from: %{source: {_table, source}}}, 0) when is_atom(source) and not is_nil(source) do
    if not schema?(source) do
      raise ArgumentError, "root query binding must be an Ecto schema source"
    end

    source
  end

  def binding_schema(%Ecto.Query{joins: joins} = query, binding_index)
      when is_integer(binding_index) and binding_index > 0 do
    join =
      Enum.at(joins, binding_index - 1) || raise ArgumentError, "query binding at index #{binding_index} does not exist"

    case join do
      %{assoc: {parent_index, association}} ->
        parent_schema = binding_schema(query, parent_index)
        association_meta = parent_schema.__schema__(:association, association)

        if is_nil(association_meta) do
          raise ArgumentError,
                "association #{inspect(association)} does not exist on #{inspect(parent_schema)}"
        end

        association_meta.related

      %{source: {_table, source}} when is_atom(source) and not is_nil(source) ->
        if not schema?(source) do
          raise ArgumentError, "query binding at index #{binding_index} must be an Ecto schema source"
        end

        source

      _other ->
        raise ArgumentError, "query binding at index #{binding_index} is not schema-backed"
    end
  end

  def binding_schema(%Ecto.Query{}, 0) do
    raise ArgumentError, "root query binding must be an Ecto schema source"
  end

  def binding_schema(%Ecto.Query{}, binding_index) when is_integer(binding_index) do
    raise ArgumentError, "query binding at index #{binding_index} does not exist"
  end

  defp schema?(source) do
    function_exported?(source, :__schema__, 2)
  end
end
