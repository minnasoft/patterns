defmodule Patterns.QueryableTest do
  use Patterns.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  defmodule DefaultPost do
    @moduledoc false

    use Ecto.Schema
    use Patterns.Queryable

    schema "patterns_posts" do
      field :title, :string
      field :views, :integer
      field :published, :boolean

      has_many :comments, Patterns.QueryableTest.DefaultComment, foreign_key: :post_id
    end
  end

  defmodule PostWithQueryableComments do
    @moduledoc false

    use Ecto.Schema
    use Patterns.Queryable

    schema "patterns_posts" do
      field :title, :string
      field :views, :integer
      field :published, :boolean

      has_many :comments, Patterns.QueryableTest.QueryableComment, foreign_key: :post_id
    end
  end

  defmodule DefaultComment do
    @moduledoc false

    use Ecto.Schema

    schema "patterns_comments" do
      field :body, :string
      field :likes, :integer
      belongs_to :post, Patterns.QueryableTest.DefaultPost
    end
  end

  defmodule QueryableComment do
    @moduledoc false

    use Ecto.Schema
    use Patterns.Queryable

    schema "patterns_comments" do
      field :body, :string
      field :likes, :integer

      belongs_to :post, Patterns.QueryableTest.PostWithQueryableComments
    end

    @impl Patterns.Queryable
    def query(base_query, filters) do
      Enum.reduce(filters, base_query, fn
        {:popular, true}, query ->
          from binding(comment) in query, where: comment.likes > 5

        {:post_title, title}, query ->
          apply_filter(query, {:post, [title: title]})

        filter, query ->
          apply_filter(query, filter)
      end)
    end
  end

  defmodule CustomPost do
    @moduledoc false

    use Ecto.Schema
    use Patterns.Queryable

    schema "patterns_posts" do
      field :title, :string
      field :views, :integer
      field :published, :boolean
    end

    @impl Patterns.Queryable
    def query(_base_query, filters) when is_map(filters) do
      raise "map filters should be normalized before user-defined query/2 clauses"
    end

    def query(base_query, filters) do
      Enum.reduce(filters, base_query, fn
        {:popular, true}, query ->
          from post in query, where: post.views > 10

        filter, query ->
          apply_filter(query, filter)
      end)
    end
  end

  defmodule PublishedPost do
    @moduledoc false

    use Ecto.Schema
    use Patterns.Queryable

    schema "patterns_posts" do
      field :title, :string
      field :views, :integer
      field :published, :boolean
    end

    @impl Patterns.Queryable
    def base_query do
      from post in __MODULE__,
        as: :self,
        where: post.published == true
    end
  end

  describe "query/1" do
    test "uses default filtering when the schema does not implement query/2" do
      Repo.insert!(%DefaultPost{title: "match", views: 1})
      Repo.insert!(%DefaultPost{title: "other", views: 2})

      results = Repo.all(from post in DefaultPost.query(title: "match"), order_by: post.title)

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "accepts map filters for schemas that use the default query/2" do
      Repo.insert!(%DefaultPost{title: "match", views: 1})
      Repo.insert!(%DefaultPost{title: "other", views: 2})

      results = Repo.all(from post in DefaultPost.query(%{title: "match"}), order_by: post.title)

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "normalizes map filters before user-defined query/2 clauses" do
      Repo.insert!(%CustomPost{title: "popular", views: 20})
      Repo.insert!(%CustomPost{title: "quiet", views: 1})

      results = Repo.all(from post in CustomPost.query(%{popular: true}), order_by: post.title)

      assert Enum.map(results, & &1.title) == ["popular"]
    end

    test "starts from custom base_query/0" do
      Repo.insert!(%PublishedPost{title: "published", published: true})
      Repo.insert!(%PublishedPost{title: "draft", published: false})

      results = Repo.all(from post in PublishedPost.query([]), order_by: post.title)

      assert Enum.map(results, & &1.title) == ["published"]
    end
  end

  describe "query/2" do
    test "applies filters to an explicit base query" do
      Repo.insert!(%DefaultPost{title: "match", views: 5})
      Repo.insert!(%DefaultPost{title: "too low", views: 1})
      Repo.insert!(%DefaultPost{title: "other", views: 10})

      base_query = from post in DefaultPost, as: :self, where: post.views > 1

      results = Repo.all(from post in DefaultPost.query(base_query, title: {:not, "other"}), order_by: post.title)

      assert Enum.map(results, & &1.title) == ["match"]
    end
  end

  describe "association filters" do
    test "filters associations using default nested filtering" do
      matching_post = Repo.insert!(%DefaultPost{title: "match"})
      other_post = Repo.insert!(%DefaultPost{title: "other"})

      Repo.insert!(%DefaultComment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%DefaultComment{post_id: other_post.id, body: "Nope", likes: 0})

      results = Repo.all(from post in DefaultPost.query(comments: [body: "Nice"]), order_by: post.title)

      assert Enum.map(results, & &1.title) == ["match"]
    end

    test "delegates nested association filters to the associated schema query/2" do
      popular_post = Repo.insert!(%PostWithQueryableComments{title: "popular"})
      quiet_post = Repo.insert!(%PostWithQueryableComments{title: "quiet"})

      Repo.insert!(%QueryableComment{post_id: popular_post.id, body: "Nice", likes: 10})
      Repo.insert!(%QueryableComment{post_id: quiet_post.id, body: "Fine", likes: 1})

      results =
        Repo.all(
          from post in PostWithQueryableComments.query(comments: [popular: true]),
            order_by: post.title
        )

      assert Enum.map(results, & &1.title) == ["popular"]
    end

    test "delegates nested association filters through the associated schema query/2" do
      matching_post = Repo.insert!(%PostWithQueryableComments{title: "match"})
      other_post = Repo.insert!(%PostWithQueryableComments{title: "other"})

      Repo.insert!(%QueryableComment{post_id: matching_post.id, body: "Nice", likes: 10})
      Repo.insert!(%QueryableComment{post_id: other_post.id, body: "Fine", likes: 10})

      results =
        Repo.all(
          from post in PostWithQueryableComments.query(comments: [post_title: "match"]),
            order_by: post.title
        )

      assert Enum.map(results, & &1.title) == ["match"]
    end
  end
end
