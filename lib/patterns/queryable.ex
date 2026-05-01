defmodule Patterns.Queryable do
  @moduledoc """
  A query-building pattern for Ecto schemas.

  `Patterns.Queryable` gives schemas a consistent `query/2` API that can be
  used by contexts, resolvers, dataloaders, and tests without duplicating filter
  logic.

  ## Basic Usage

      defmodule Blog.Post do
        use Ecto.Schema
        use Patterns.Queryable

        schema "posts" do
          field :title, :string
          field :published, :boolean
        end
      end

      Blog.Repo.all(Blog.Post.query(title: "Hello"))
      Blog.Repo.all(Blog.Post.query(%{title: "Hello"}))

  Modules that use `Patterns.Queryable` get default implementations of
  `base_query/0` and `query/2`. The default `query/2` reduces filters through
  `apply_filter/2`, which is delegated from `Patterns.Queryable.Filters`.

  `query/2` takes an optional base query as its first parameter. Callers can use
  `query(filters)` to start from `base_query/0`, or `query(base_query, filters)`
  to apply filters to an existing query.

  > #### Prefer keyword filters {: .info}
  >
  > `Patterns.Queryable` strongly recommends passing filters as keyword lists.
  > Filter order is meaningful because filters are applied from left to right.
  > Maps are accepted for convenience, but map iteration order is not part of the
  > filtering API and should not be used when ordering semantics matter.

  ## Base Queries

  `base_query/0` defines the starting point for `query/2`. By default, it returns
  a query over the using schema.

      from post in Blog.Post

  Override `base_query/0` when every query for a schema should start with shared
  constraints, joins, ordering, or named bindings.

      @impl Patterns.Queryable
      def base_query do
        from post in __MODULE__,
          where: post.published == true
      end

  ## Query DSL

  `use Patterns.Queryable` imports `Patterns.Queryable.DSL.from/2`, which wraps
  Ecto's `from` macro and adds `binding/1` and `binding/2` source patterns for
  query composition.

  `binding/1` targets the current scoped binding set by `with_ctx/2`. When no
  scoped binding is set, it targets the root query binding.

      from binding(post) in query,
        where: post.title == ^title

  `binding/2` targets an explicit named binding.

      from binding(:comments, comment) in query,
        where: comment.body == ^body

  ## Default Filters

  `Patterns.Queryable.Filters.apply_filter/2` provides reusable filters for query
  modifiers, field comparators, and association comparators.

      Blog.Post.query(
        title: {:not, nil},
        views: {:gte, 100},
        comments: [body: "Nice"]
      )

  See `Patterns.Queryable.Filters` for the full `apply_filter/2` reference.

  ## Filtering Associations

  Association filters use the literal association names defined in the schema as
  filter keys.

      defmodule Blog.Post do
        use Ecto.Schema
        use Patterns.Queryable

        schema "posts" do
          field :title, :string
          has_many :comments, Blog.Comment
        end
      end

      Blog.Repo.all(Blog.Post.query(comments: [body: "Nice"]}))

  In this example, `:comments` works because `Blog.Post` defines
  `has_many :comments, Blog.Comment`. `Patterns.Queryable` joins that
  association using the association name as the binding name, then applies the
  nested filters to that binding.

  If the query already has a named binding for the association, that binding is
  reused instead of adding another join.

  > #### Association filters use joins {: .warning}
  >
  > Association filters use joins, so `has_many` and `many_to_many` filters can
  > return duplicate parent rows. Pass `distinct: true` when parent row uniqueness
  > matters. Existing named bindings keep their original join semantics.

  Association filters use Ecto's `assoc/2` join syntax on the parent query. When
  the associated schema implements `query/2`, nested filters are delegated to
  that function against the joined association binding. Otherwise, nested filters
  are applied using the default filters from `Patterns.Queryable.Filters`.

  > #### Association base queries {: .info}
  >
  > The associated schema's `base_query/0` is not applied because the query is
  > still rooted at the parent schema, not the association schema.

  This may change in the future if `Patterns.Queryable` grows an explicit way to
  compose association base-query constraints onto joined bindings.

  When implementing custom association filters, use `with_ctx/2` to tell
  `binding/1` which named binding nested filters should target.

      @impl Patterns.Queryable
      def query(base_query, filters) do
        Enum.reduce(filters, base_query, fn
          {:approved_comments, comment_filters}, query ->
            query =
              from post in query,
                join: comment in assoc(post, :comments),
                as: :approved_comments,
                where: comment.approved == true

            {query, _ctx} = with_ctx binding: :approved_comments do
              Blog.Comment.query(query, comment_filters)
            end

            query

          filter, query ->
            apply_filter(query, filter)
        end)
      end

  ## Custom Filters

  Define `query/2` when a schema needs custom filters. Custom implementations
  should handle keyword filters only; map filters are normalized before
  user-defined clauses run. Use `binding/1` for filters that should work both on
  the schema's root query and when delegated through association filters.

  Future releases may add custom lint rules to catch `query/2` callback clauses
  that use plain `from x in query` when `from binding(x) in query` is required
  for association delegation.

      defmodule Blog.Post do
        use Ecto.Schema
        use Patterns.Queryable

        schema "posts" do
          field :title, :string
          field :published_at, :utc_datetime
        end

        @impl Patterns.Queryable
        def query(base_query, filters) do
          Enum.reduce(filters, base_query, fn
            {:published, true}, query ->
              from binding(post) in query,
                where: not is_nil(post.published_at)

            filter, query ->
              apply_filter(query, filter)
          end)
        end
      end

  ## Defaults And Clause Ordering

  `Patterns.Queryable` injects a map-normalizing `query/2` clause before user
  clauses and a default keyword-filter fallback after user clauses. This lets
  callers pass either maps or keyword lists while allowing schemas to implement
  only the keyword-filter case.

  A user-defined catch-all `query/2` clause prevents the generated fallback from
  running. In that case, the implementation owns all keyword filtering and should
  delegate unknown filters to `apply_filter/2` when default behavior is desired.
  """
  import Patterns.Utils, only: [defdelegate_all: 1]

  defdelegate_all Patterns.Queryable.Filters

  @doc """
  Sets up a schema module as `Patterns.Queryable`.

  Imports the query DSL, defines the default `base_query/0`, injects map filter
  normalization, and provides a fallback `query/2` implementation when the using
  module does not define one.

  See the module documentation for examples.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      import Ecto.Query, except: [from: 1, from: 2]
      import Patterns.Queryable
      import Patterns.Queryable.DSL, only: [from: 1, from: 2]

      alias Patterns.Queryable

      @impl unquote(__MODULE__)
      def base_query do
        from(x in __MODULE__)
      end

      @impl unquote(__MODULE__)
      def query(base_query \\ base_query(), filters)

      def query(base_query, filters) when is_map(filters) do
        query(base_query, Map.to_list(filters))
      end

      @before_compile unquote(__MODULE__)

      defoverridable base_query: 0
    end
  end

  # HACK: Users should be able to call query/2 without defining it, and maps
  #       should normalize to keyword filters automatically.
  #       Users should also be able to implement query/2 themselves, but only for the
  #       keyword-filter case.
  #       To get both behaviors, __using__/1 injects the map-normalizing clause before
  #       user clauses, and this @before_compile hook injects the default keyword
  #       fallback after user clauses.
  defmacro __before_compile__(_env) do
    quote do
      @impl unquote(__MODULE__)
      def query(base_query, filters) do
        Enum.reduce(filters, base_query, &apply_filter(&2, &1))
      end
    end
  end

  @type filters :: map() | keyword()

  @doc """
  Builds a query from `base_query` and `filters`.

  Implement this callback when a schema needs custom filters. Implementations
  should expect keyword filters; map filters are normalized before user-defined
  clauses run.
  """
  @callback query(Ecto.Queryable.t(), filters()) :: Ecto.Queryable.t()

  @doc """
  Returns the default query used when callers invoke `query(filters)`.

  The default implementation queries the using schema.
  """
  @callback base_query() :: Ecto.Queryable.t()
  @optional_callbacks base_query: 0, query: 2
end
