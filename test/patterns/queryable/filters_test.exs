defmodule Patterns.Queryable.FiltersTest do
  use Patterns.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Patterns.Queryable.Filters
  alias Patterns.Test.Comment
  alias Patterns.Test.Post

  require Ecto.Query

  describe "apply_filter/2" do
    test "filters schema modules" do
      Repo.insert!(%Post{title: "match"})
      Repo.insert!(%Post{title: "other"})

      results =
        Post
        |> Filters.apply_filter({:title, "match"})
        |> Repo.all()

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "filters plain root queries without a self binding" do
      Repo.insert!(%Post{title: "match"})
      Repo.insert!(%Post{title: "other"})

      results =
        Post
        |> Ecto.Query.from()
        |> Filters.apply_filter({:title, "match"})
        |> Repo.all()

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "passes query modifier values through to Ecto" do
      post = Repo.insert!(%Post{title: "post"})
      Repo.insert!(%Comment{post_id: post.id, body: "comment"})

      query =
        Post
        |> Filters.apply_filter({:preload, :comments})
        |> Filters.apply_filter({:preload, comments: :post})

      equivalent_query = from(post in Post, preload: [:comments, comments: :post])

      assert SQL.to_sql(:all, Repo, query) == SQL.to_sql(:all, Repo, equivalent_query)
      assert [%{comments: [%Comment{body: "comment"}]}] = Repo.all(query)

      query = Filters.apply_filter(from(post in Post, as: :self, select: post.title), {:distinct, true})

      equivalent_query = from(post in Post, distinct: true, select: post.title)

      assert SQL.to_sql(:all, Repo, query) == SQL.to_sql(:all, Repo, equivalent_query)

      query = Filters.apply_filter(from(post in Post, as: :self), {:select, :title})

      equivalent_query = from(post in Post, select: post.title)

      assert SQL.to_sql(:all, Repo, query) == SQL.to_sql(:all, Repo, equivalent_query)
    end

    test "applies limit and offset modifiers" do
      Repo.insert!(%Post{title: "alpha"})
      Repo.insert!(%Post{title: "beta"})
      Repo.insert!(%Post{title: "gamma"})

      results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:limit, 1})
        |> Filters.apply_filter({:offset, 1})
        |> Repo.all()
        |> Enum.map(& &1.title)

      assert results == ["beta"]
    end

    test "applies literal select modifiers" do
      Repo.insert!(%Post{title: "alpha"})

      results =
        Post
        |> Filters.apply_filter({:select, %{source: "constant"}})
        |> Repo.all()

      assert results == [%{source: "constant"}]
    end

    test "applies equality comparators" do
      Repo.insert!(%Post{title: "alpha", views: nil, published: true})
      Repo.insert!(%Post{title: "beta", views: 2, published: false})
      Repo.insert!(%Post{title: "gamma", views: 3, published: false})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert ["alpha"] =
               query
               |> Filters.apply_filter({:title, "alpha"})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["alpha"] =
               query
               |> Filters.apply_filter({:published, {:eq, true}})
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "applies nil comparators" do
      Repo.insert!(%Post{title: "alpha", views: nil})
      Repo.insert!(%Post{title: "beta", views: 2})
      Repo.insert!(%Post{title: "gamma", views: 3})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert ["alpha"] =
               query
               |> Filters.apply_filter({:views, {:eq, nil}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["alpha"] =
               query
               |> Filters.apply_filter({:views, nil})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["beta", "gamma"] =
               query
               |> Filters.apply_filter({:views, {:not, nil}})
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "applies list comparators" do
      Repo.insert!(%Post{title: "alpha"})
      Repo.insert!(%Post{title: "beta"})
      Repo.insert!(%Post{title: "gamma"})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert ["alpha", "gamma"] =
               query
               |> Filters.apply_filter({:title, ["gamma", "alpha"]})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["alpha", "gamma"] =
               query
               |> Filters.apply_filter({:title, {:in, ["gamma", "alpha"]}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert [] =
               query
               |> Filters.apply_filter({:title, []})
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "applies negation comparators" do
      Repo.insert!(%Post{title: "alpha"})
      Repo.insert!(%Post{title: "beta"})
      Repo.insert!(%Post{title: "gamma"})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert ["beta"] =
               query
               |> Filters.apply_filter({:title, {:not, ["alpha", "gamma"]}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["beta"] =
               query
               |> Filters.apply_filter({:title, {:not_in, ["alpha", "gamma"]}})
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "applies range comparators" do
      Repo.insert!(%Post{title: "low", views: 1})
      Repo.insert!(%Post{title: "mid", views: 2})
      Repo.insert!(%Post{title: "high", views: 3})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert ["high", "mid"] =
               query
               |> Filters.apply_filter({:views, {:gte, 2}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["low", "mid"] =
               query
               |> Filters.apply_filter({:views, {:lt, 3}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["mid"] =
               query
               |> Filters.apply_filter({:views, {:gt, 1}})
               |> Filters.apply_filter({:views, {:lte, 3}})
               |> Filters.apply_filter({:title, {:not, "high"}})
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "applies like comparators" do
      Repo.insert!(%Post{title: "Alpha"})
      Repo.insert!(%Post{title: "alphabet"})
      Repo.insert!(%Post{title: "beta"})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert_like_sql(query, {:title, {:like, "alpha%"}}, "LIKE", "alpha%")
      assert_like_sql(query, {:title, {:not_like, "alpha%"}}, "NOT (", "alpha%")
    end

    test "applies regex shorthand" do
      Repo.insert!(%Post{title: "Alpha"})
      Repo.insert!(%Post{title: "alphabet"})
      Repo.insert!(%Post{title: "beta"})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert_like_sql(query, {:title, ~r/^alpha.*/}, "LIKE", "alpha%")
      refute_like_sql(query, {:title, ~r/^alpha.*/}, "lower(")

      # NOTE: SQLite LIKE is case-insensitive by default, so keep non-i regex
      # execution coverage on same-case data and assert SQL shape separately.
      assert ["alphabet"] =
               query
               |> Filters.apply_filter({:title, ~r/lphab/})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["beta"] =
               query
               |> Filters.apply_filter({:title, ~r/ta$/})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert_like_sql(query, {:title, {:like, ~r/^alpha.*/}}, "LIKE", "alpha%")

      assert_like_sql(query, {:title, {:not_like, ~r/^alpha.*/}}, "NOT (", "alpha%")

      assert_like_sql(query, {:title, {:not, ~r/^alpha.*/}}, "NOT (", "alpha%")
    end

    test "applies caseless regex shorthand" do
      Repo.insert!(%Post{title: "Alpha"})
      Repo.insert!(%Post{title: "alphabet"})
      Repo.insert!(%Post{title: "beta"})

      query = Ecto.Query.from(post in Post, as: :self, order_by: post.title)

      assert ["Alpha", "alphabet"] =
               query
               |> Filters.apply_filter({:title, {:like, ~r/^ALPHA.*/i}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert_like_sql(query, {:title, {:like, ~r/^ALPHA.*/i}}, "lower(", "alpha%")

      assert_like_sql(query, {:title, ~r/^ALPHA.*/i}, "lower(", "alpha%")

      assert ["beta"] =
               query
               |> Filters.apply_filter({:title, {:not, ~r/^ALPHA.*/i}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert ["beta"] =
               query
               |> Filters.apply_filter({:title, {:not_like, ~r/^ALPHA.*/i}})
               |> Repo.all()
               |> Enum.map(& &1.title)

      assert_like_sql(query, {:title, {:not_like, ~r/^ALPHA.*/i}}, "lower(", "alpha%")
    end

    test "raises for unsupported contains comparator" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported filter comparator :contains for field :title", fn ->
        Filters.apply_filter(query, {:title, {:contains, "alpha"}})
      end
    end

    test "raises for unsupported between comparator" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported filter comparator :between for field :views", fn ->
        Filters.apply_filter(query, {:views, {:between, 1, 3}})
      end
    end

    test "ignores unsupported filter shapes" do
      Repo.insert!(%Post{title: "alpha"})

      query = Ecto.Query.from(post in Post, as: :self)

      assert Repo.all(Filters.apply_filter(query, :unsupported)) == Repo.all(query)
    end

    test "raises for regex groups and alternation" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/alph(a|b)/})
      end
    end

    test "raises for regex SQL wildcard literals" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/foo_bar/})
      end

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/foo%bar/})
      end
    end

    test "raises for escaped regex syntax" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/foo\.bar/})
      end
    end

    test "raises for unsupported regex quantifiers" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/fo*/})
      end
    end

    test "raises for internal regex anchors" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/fo^o/})
      end

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/fo$o/})
      end
    end

    test "raises for repeated regex anchors" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/^^foo/})
      end

      assert_raise ArgumentError, "unsupported regex syntax for LIKE filter", fn ->
        Filters.apply_filter(query, {:title, ~r/foo$$/})
      end
    end

    test "raises for unsupported regex options" do
      query = Ecto.Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "unsupported regex options for LIKE filter: [:ungreedy]", fn ->
        Filters.apply_filter(query, {:title, ~r/alpha/U})
      end
    end

    test "ignores query modifiers inside association filters" do
      matching_post = Repo.insert!(%Post{title: "match"})
      other_post = Repo.insert!(%Post{title: "other"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: other_post.id, body: "Nope", likes: 0})

      results =
        Post
        |> Filters.apply_filter({:comments, [body: "Nice", limit: 0, select: :id]})
        |> Repo.all()

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "applies association filters from schema modules" do
      matching_post = Repo.insert!(%Post{title: "match"})
      other_post = Repo.insert!(%Post{title: "other"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: other_post.id, body: "Nope", likes: 0})

      results =
        Post
        |> Filters.apply_filter({:comments, [body: "Nice"]})
        |> Repo.all()

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "applies association filters from plain root queries without a self binding" do
      matching_post = Repo.insert!(%Post{title: "match"})
      other_post = Repo.insert!(%Post{title: "other"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: other_post.id, body: "Nope", likes: 0})

      results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:comments, [body: "Nice"]})
        |> Repo.all()
        |> Enum.map(& &1.title)

      assert results == ["match"]
    end

    test "empty association filters match parents with associated rows" do
      matching_post = Repo.insert!(%Post{title: "match"})
      Repo.insert!(%Post{title: "missing"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})

      keyword_results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:comments, []})
        |> Repo.all()
        |> Enum.map(& &1.title)

      map_results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:comments, %{}})
        |> Repo.all()
        |> Enum.map(& &1.title)

      assert keyword_results == ["match"]
      assert map_results == ["match"]
    end

    test "association filters keep join multiplicity unless distinct is requested" do
      matching_post = Repo.insert!(%Post{title: "match"})
      other_post = Repo.insert!(%Post{title: "other"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 20})
      Repo.insert!(%Comment{post_id: other_post.id, body: "Nope", likes: 0})

      duplicated_results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:comments, [body: "Nice"]})
        |> Repo.all()
        |> Enum.map(& &1.title)

      distinct_results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:comments, [body: "Nice"]})
        |> Filters.apply_filter({:distinct, true})
        |> Repo.all()
        |> Enum.map(& &1.title)

      assert duplicated_results == ["match", "match"]
      assert distinct_results == ["match"]
    end

    test "association filters reuse an existing named association binding" do
      matching_post = Repo.insert!(%Post{title: "match"})
      other_post = Repo.insert!(%Post{title: "other"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: other_post.id, body: "Nope", likes: 0})

      query =
        Post
        |> Ecto.Query.from(as: :self, order_by: [asc: :title])
        |> Ecto.Query.join(:inner, [post], comment in assoc(post, :comments), as: :comments)
        |> Filters.apply_filter({:comments, [body: "Nice"]})

      assert length(query.joins) == 1

      assert ["match"] =
               query
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "association filters preserve existing left join binding semantics" do
      matching_post = Repo.insert!(%Post{title: "match"})
      Repo.insert!(%Post{title: "missing"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: nil, likes: 10})

      query =
        Post
        |> Ecto.Query.from(as: :self, order_by: [asc: :title])
        |> Ecto.Query.join(:left, [post], comment in assoc(post, :comments), as: :comments)
        |> Filters.apply_filter({:comments, [body: nil]})

      assert length(query.joins) == 1

      assert ["match", "missing"] =
               query
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "empty association filters preserve existing left join binding semantics" do
      matching_post = Repo.insert!(%Post{title: "match"})
      Repo.insert!(%Post{title: "missing"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})

      query =
        Post
        |> Ecto.Query.from(as: :self, order_by: [asc: :title])
        |> Ecto.Query.join(:left, [post], comment in assoc(post, :comments), as: :comments)
        |> Filters.apply_filter({:comments, []})

      assert length(query.joins) == 1

      assert ["match", "missing"] =
               query
               |> Repo.all()
               |> Enum.map(& &1.title)
    end

    test "association filters require schema-backed query sources" do
      query = Ecto.Query.from(post in "patterns_posts", as: :self)

      assert_raise ArgumentError, "root query binding must be an Ecto schema source", fn ->
        Filters.apply_filter(query, {:comments, [body: "Nice"]})
      end
    end

    test "applies nested association filters from the current scoped binding" do
      matching_post = Repo.insert!(%Post{title: "match"})
      other_post = Repo.insert!(%Post{title: "other"})

      Repo.insert!(%Comment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: other_post.id, body: "Fine", likes: 1})

      results =
        Post
        |> Ecto.Query.from(order_by: [asc: :title])
        |> Filters.apply_filter({:comments, [post: [title: "match"]]})
        |> Repo.all()
        |> Enum.map(& &1.title)

      assert results == ["match"]
    end

    test "applies association comparators to the association binding" do
      popular_post = Repo.insert!(%Post{title: "popular"})
      quiet_post = Repo.insert!(%Post{title: "quiet"})

      Repo.insert!(%Comment{post_id: popular_post.id, body: "Nice", likes: 10})
      Repo.insert!(%Comment{post_id: quiet_post.id, body: "Fine", likes: 1})

      results =
        Post
        |> Filters.apply_filter({:comments, %{likes: {:gte, 5}}})
        |> Repo.all()

      assert Enum.map(results, & &1.title) == ["popular"]
    end
  end

  defp assert_like_sql(query, filter, sql_fragment, pattern) do
    {sql, params} =
      SQL.to_sql(:all, Repo, Filters.apply_filter(query, filter))

    assert sql =~ sql_fragment
    assert params == [pattern]
  end

  defp refute_like_sql(query, filter, sql_fragment) do
    {sql, _params} =
      SQL.to_sql(:all, Repo, Filters.apply_filter(query, filter))

    refute sql =~ sql_fragment
  end
end
