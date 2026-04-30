defmodule Patterns.Queryable.Filters do
  @moduledoc """
  Default filter implementations for `Patterns.Queryable` modules.

  `apply_filter/2` turns common filter tuples into Ecto query expressions so a
  `Patterns.Queryable` module can focus on custom filters and delegate the rest.

  ## Query Modifiers

  Query modifiers affect only the top-level query. They are ignored inside
  association filters.

  Supported modifiers are:

  * `{:distinct, value}`
  * `{:limit, value}`
  * `{:offset, value}`
  * `{:preload, value}`
  * `{:select, value}`

  Modifier values are forwarded to Ecto's query DSL, so Ecto syntax like
  `{:preload, :comments}`, `{:preload, [comments: :post]}`, and
  `{:distinct, true}` is supported. Atom selects are treated as fields on the
  current binding, so `{:select, :id}` selects the current binding's `id` field.
  Non-atom selects are passed through to Ecto as values. Distinct values are
  forwarded to Ecto; use `{:distinct, true}` as the portable parent-deduplication
  form for association filters.

  Modifier behavior is delegated to Ecto and the configured adapter. SQL shape
  and support can differ between adapters such as `ecto_sqlite3` and PostgreSQL,
  especially for non-boolean `distinct` values and complex preloads.

  ## Field Comparators

  Field comparators apply predicates to the current binding.

  Supported comparators are:

  * `{field, value}` and `{field, {:eq, value}}`
  * `{field, nil}` and `{field, {:eq, nil}}`
  * `{field, [value]}` and `{field, {:in, [value]}}`
  * `{field, %Regex{}}` and `{field, {:like, %Regex{}}}`
  * `{field, {:not, value}}`
  * `{field, {:not, nil}}`
  * `{field, {:not, [value]}}` and `{field, {:not_in, [value]}}`
  * `{field, {:not, %Regex{}}}` and `{field, {:not_like, %Regex{}}}`
  * `{field, {:gt, value}}`
  * `{field, {:gte, value}}`
  * `{field, {:lt, value}}`
  * `{field, {:lte, value}}`
  * `{field, {:like, pattern}}`
  * `{field, {:not_like, pattern}}`

  Unsupported comparator tuples raise `ArgumentError` instead of silently
  becoming equality comparisons against the tuple value.

  ### Regex Values

  > #### Regex shorthand is LIKE shorthand {: .warning}
  >
  > Regex values are shorthand for SQL `LIKE` patterns, not full database regex
  > predicates. They are converted by translating `.*` to `%` and `.` to `_`.
  > Unanchored regexes are padded with `%`; `^` and `$` suppress leading and
  > trailing padding respectively.

  The `i` regex option lower-cases the field and generated `LIKE` pattern.
  Other regex options raise `ArgumentError`.

  Matching semantics are still delegated to the database adapter and collation.
  For example, plain SQL `LIKE` case-sensitivity can differ between SQLite and
  PostgreSQL.

  Literal `%` and `_` are rejected in regex shorthand because they are SQL `LIKE`
  wildcards. Escaped regex syntax is not supported.

  Regex syntax that cannot be represented by this simple conversion raises
  `ArgumentError`.

  ## Association Comparators

  Association comparators use `{field, filters}` where `filters` is a map or
  keyword-shaped list and `field` is an Ecto association.

  Empty filters like `{:comments, []}` and `{:comments, %{}}` still join the
  association. When `Patterns.Queryable` adds a new inner join, they match
  parents with at least one associated row. When an existing named binding is
  reused, that binding's join semantics are preserved.

  Treating map and keyword values as association filters is an implementation
  detail. Future versions may support map equality for field types that can
  encode and compare maps directly, such as PostgreSQL `jsonb` fields.

  Association filters require a schema-backed query source because they inspect
  association metadata from the current scoped binding. Raw string sources and
  subquery sources cannot use association filters.

  Join generation and association metadata are delegated to Ecto. Adapter SQL
  output may differ, but the filter semantics are based on Ecto's `assoc/2` join
  behavior.

  Nested association filters are resolved from the current scoped binding, so
  `{:comments, [post: [title: "Hello"]]}` filters `:post` as an association of
  the joined `:comments` binding.

  Association filters use Ecto's `assoc/2` join syntax and keep normal join
  semantics. For `has_many` and `many_to_many` associations, one parent row is
  returned for each matching associated row. Pass `{:distinct, true}` when parent
  row uniqueness matters.

  > #### Named binding reuse {: .warning}
  >
  > If the query already has a named binding for the association, that binding is
  > reused instead of adding another join. Reusing an existing binding preserves
  > that binding's join semantics, including left-join behavior. Named bindings are
  > query-global, so nested association filters can reuse an existing binding with
  > the same association name. Implement custom `query/2` clauses when a nested
  > association path needs stricter binding control.

  When the associated schema exports `query/2`, nested filters are delegated to
  that function against the joined association binding. Otherwise, each nested
  filter is applied directly to the joined association binding.

  Binding resolution uses `Patterns.Queryable.DSL.binding_schema/1`, so nested
  association filters are resolved from the current scoped binding rather than
  always from the root query source.
  """

  import Ecto.Query, except: [from: 1, from: 2]
  import Patterns.Guards, only: [is_keyword: 1]
  import Patterns.Queryable.DSL, only: [from: 1, from: 2]
  import Patterns.Utils, only: [with_ctx: 2]

  alias Patterns.Queryable.DSL

  @query_modifiers [:distinct, :limit, :offset, :preload, :select]

  defguardp caseless?(regex) when is_struct(regex, Regex) and regex.opts == [:caseless]

  @doc """
  Applies a single query filter.

  See the module documentation for supported filter shapes.
  """
  @spec apply_filter(Ecto.Queryable.t(), {field :: atom(), value :: term()}) :: Ecto.Queryable.t()
  def apply_filter(query, filter) when is_atom(query) do
    apply_filter(from(x in query), filter)
  end

  def apply_filter(%Ecto.Query{} = query, {field, filters} = filter)
      when is_keyword(filters) or (is_map(filters) and not is_struct(filters)) do
    filters = if is_map(filters), do: Keyword.new(filters), else: filters
    source = DSL.binding_schema(query)

    association_meta = source.__schema__(:association, field)
    association_module = association_meta && association_meta.related

    if is_nil(association_module) do
      do_apply_filter(query, filter)
    else
      do_apply_assoc_filter(association_module, query, {field, filters})
    end
  end

  def apply_filter(query, filter) do
    do_apply_filter(query, filter)
  end

  defp do_apply_filter(query, {:distinct, value}) do
    from(x in query, distinct: ^value)
  end

  defp do_apply_filter(query, {:limit, value}) do
    from(x in query, limit: ^value)
  end

  defp do_apply_filter(query, {:offset, value}) do
    from(x in query, offset: ^value)
  end

  defp do_apply_filter(query, {:preload, value}) do
    from(x in query, preload: ^value)
  end

  defp do_apply_filter(query, {:select, value}) when is_atom(value) do
    from binding(x) in query, select: field(x, ^value)
  end

  defp do_apply_filter(query, {:select, value}) do
    from(x in query, select: ^value)
  end

  defp do_apply_filter(query, {field, {:eq, nil}}) do
    from binding(x) in query, where: is_nil(field(x, ^field))
  end

  defp do_apply_filter(query, {field, {:eq, value}}) do
    from binding(x) in query, where: field(x, ^field) == ^value
  end

  defp do_apply_filter(query, {field, {:in, value}}) when is_list(value) do
    from binding(x) in query, where: field(x, ^field) in ^value
  end

  defp do_apply_filter(query, {field, {:not_in, value}}) when is_list(value) do
    from binding(x) in query, where: field(x, ^field) not in ^value
  end

  defp do_apply_filter(query, {field, {:gt, value}}) do
    from binding(x) in query, where: field(x, ^field) > ^value
  end

  defp do_apply_filter(query, {field, {:gte, value}}) do
    from binding(x) in query, where: field(x, ^field) >= ^value
  end

  defp do_apply_filter(query, {field, {:lt, value}}) do
    from binding(x) in query, where: field(x, ^field) < ^value
  end

  defp do_apply_filter(query, {field, {:lte, value}}) do
    from binding(x) in query, where: field(x, ^field) <= ^value
  end

  defp do_apply_filter(query, {field, {:like, %Regex{} = value}}) when caseless?(value) do
    from binding(x) in query, where: like(fragment("lower(?)", field(x, ^field)), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, {:like, %Regex{} = value}}) do
    from binding(x) in query, where: like(field(x, ^field), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, {:like, value}}) do
    from binding(x) in query, where: like(field(x, ^field), ^value)
  end

  defp do_apply_filter(query, {field, {:not_like, %Regex{} = value}}) when caseless?(value) do
    from binding(x) in query, where: not like(fragment("lower(?)", field(x, ^field)), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, {:not_like, %Regex{} = value}}) do
    from binding(x) in query, where: not like(field(x, ^field), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, {:not_like, value}}) do
    from binding(x) in query, where: not like(field(x, ^field), ^value)
  end

  defp do_apply_filter(query, {field, {:not, %Regex{} = value}}) when caseless?(value) do
    from binding(x) in query, where: not like(fragment("lower(?)", field(x, ^field)), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, {:not, %Regex{} = value}}) do
    from binding(x) in query, where: not like(field(x, ^field), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, {:not, value}}) when is_list(value) do
    from binding(x) in query, where: field(x, ^field) not in ^value
  end

  defp do_apply_filter(query, {field, {:not, nil}}) do
    from binding(x) in query, where: not is_nil(field(x, ^field))
  end

  defp do_apply_filter(query, {field, {:not, value}}) do
    from binding(x) in query, where: field(x, ^field) != ^value
  end

  defp do_apply_filter(query, {field, nil}) do
    from binding(x) in query, where: is_nil(field(x, ^field))
  end

  defp do_apply_filter(query, {field, value}) when is_list(value) do
    from binding(x) in query, where: field(x, ^field) in ^value
  end

  defp do_apply_filter(query, {field, %Regex{} = value}) when caseless?(value) do
    from binding(x) in query, where: like(fragment("lower(?)", field(x, ^field)), ^regex_to_like(value))
  end

  defp do_apply_filter(query, {field, %Regex{} = value}) do
    from binding(x) in query, where: like(field(x, ^field), ^regex_to_like(value))
  end

  defp do_apply_filter(_query, {field, value}) when is_tuple(value) and is_atom(elem(value, 0)) do
    comparator = elem(value, 0)
    raise ArgumentError, "unsupported filter comparator #{inspect(comparator)} for field #{inspect(field)}"
  end

  defp do_apply_filter(query, {field, value}) do
    from binding(x) in query, where: field(x, ^field) == ^value
  end

  defp do_apply_filter(query, _unsupported) do
    query
  end

  # Filter DSL for association filters. Uses `assoc.query/2` if defined,
  # otherwise applies filters directly to the association join.
  defp do_apply_assoc_filter(assoc, query, {field, filters}) do
    filters = Enum.reject(filters, fn {key, _value} -> key in @query_modifiers end)

    query =
      with_named_binding(query, field, fn query ->
        from binding(x) in query, join: assoc(x, ^field), as: ^field
      end)

    with_ctx binding: field do
      if Code.ensure_loaded?(assoc) and function_exported?(assoc, :query, 2) do
        apply(assoc, :query, [query, filters])
      else
        Enum.reduce(filters, query, fn filter, query -> apply_filter(query, filter) end)
      end
    end
  end

  defp regex_to_like(%Regex{source: source, opts: opts}) do
    unsupported_opts = opts -- [:caseless]

    if unsupported_opts != [] do
      raise ArgumentError, "unsupported regex options for LIKE filter: #{inspect(unsupported_opts)}"
    end

    if String.starts_with?(source, "^^") or String.ends_with?(source, "$$") or
         String.contains?(source, ["\\", "%", "_", "[", "]", "(", ")", "{", "}", "+", "?", "|"]) or
         String.contains?(String.replace(source, ".*", ""), "*") or
         String.contains?(String.trim_leading(source, "^"), "^") or
         String.contains?(String.trim_trailing(source, "$"), "$") do
      raise ArgumentError, "unsupported regex syntax for LIKE filter"
    end

    leading = if String.starts_with?(source, "^"), do: "", else: "%"
    trailing = if String.ends_with?(source, "$"), do: "", else: "%"

    pattern =
      source
      |> String.trim_leading("^")
      |> String.trim_trailing("$")
      |> String.replace(".*", "%")
      |> String.replace(".", "_")

    pattern = String.replace(leading <> pattern <> trailing, ~r/%+/, "%")

    if :caseless in opts do
      String.downcase(pattern)
    else
      pattern
    end
  end
end
