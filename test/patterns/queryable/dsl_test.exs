defmodule Patterns.Queryable.DSLTest do
  use Patterns.DataCase, async: true

  import Ecto.Query, only: [subquery: 1]
  import Patterns.Utils, only: [with_ctx: 2]

  alias Ecto.Adapters.SQL
  alias Ecto.Query
  alias Patterns.Queryable.DSL
  alias Patterns.Test.Comment
  alias Patterns.Test.Post

  require DSL

  describe "from/2" do
    test "matches Ecto for schema atom sources" do
      assert_same_query(
        Query.from(post in Post, where: post.title == "post"),
        DSL.from(post in Post, where: post.title == "post")
      )
    end

    test "matches Ecto for query struct sources" do
      base_query = Query.from(post in Post, where: is_nil(post.deleted_at))

      assert_same_query(
        Query.from(post in base_query, where: post.title == "post"),
        DSL.from(post in base_query, where: post.title == "post")
      )
    end

    test "matches Ecto for bare query sources" do
      base_query = Query.from(post in Post, where: is_nil(post.deleted_at))

      assert_same_query(
        Query.from(base_query, where: [title: "post"]),
        DSL.from(base_query, where: [title: "post"])
      )
    end

    test "matches Ecto for composed query helpers" do
      base_query = Query.from(post in Post, where: post.title == "post")

      assert_same_query(
        Query.from(post in base_query, select: post.title),
        DSL.from(post in base_query, select: post.title)
      )
    end

    test "matches Ecto for subqueries" do
      subquery = Query.from(post in Post, where: is_nil(post.deleted_at), select: %{title: post.title})

      assert_same_query(
        Query.from(post in subquery(subquery), where: post.title == "post", select: post.title),
        DSL.from(post in subquery(subquery), where: post.title == "post", select: post.title)
      )
    end

    test "matches Ecto for raw source strings" do
      assert_same_query(
        Query.from(post in "patterns_posts", where: post.title == "post", select: post.title),
        DSL.from(post in "patterns_posts", where: post.title == "post", select: post.title)
      )
    end

    test "matches Ecto for joins, preloads, ordering, limits, and offsets" do
      assert_same_query(
        Query.from(post in Post,
          join: comment in assoc(post, :comments),
          where: comment.body == "comment",
          order_by: [asc: post.title],
          limit: 10,
          offset: 1,
          preload: [comments: comment]
        ),
        DSL.from(post in Post,
          join: comment in assoc(post, :comments),
          where: comment.body == "comment",
          order_by: [asc: post.title],
          limit: 10,
          offset: 1,
          preload: [comments: comment]
        )
      )
    end

    test "matches Ecto for positional binding lists" do
      base_query =
        Query.from(post in Post,
          join: comment in assoc(post, :comments)
        )

      assert_same_query(
        Query.from([post, comment] in base_query, where: post.title == "post" and comment.body == "comment"),
        DSL.from([post, comment] in base_query, where: post.title == "post" and comment.body == "comment")
      )
    end

    test "matches Ecto for ellipsis binding lists" do
      base_query =
        Query.from(post in Post,
          join: comment in assoc(post, :comments)
        )

      assert_same_query(
        Query.from([..., comment] in base_query, where: comment.body == "comment"),
        DSL.from([..., comment] in base_query, where: comment.body == "comment")
      )
    end

    test "matches Ecto for mixed named binding lists" do
      base_query =
        Query.from(post in Post,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      assert_same_query(
        Query.from([post, comments: comment] in base_query,
          where: post.title == "post" and comment.body == "comment"
        ),
        DSL.from([post, comments: comment] in base_query,
          where: post.title == "post" and comment.body == "comment"
        )
      )
    end

    test "binding/1 targets the current scoped binding" do
      base_query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      query =
        with_ctx binding: :comments do
          DSL.from(binding(comment) in base_query, where: comment.body == "comment")
        end

      equivalent_query =
        Query.from([comments: comment] in base_query, where: comment.body == "comment")

      assert_same_query(equivalent_query, query)
    end

    test "binding/1 defaults to the root binding" do
      base_query = Query.from(post in Post)

      query = DSL.from(binding(post) in base_query, where: post.title == "post")
      equivalent_query = Query.from([post] in base_query, where: post.title == "post")

      assert_same_query(equivalent_query, query)
    end

    test "binding/2 targets an explicit named binding" do
      base_query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      query = DSL.from(binding(:comments, comment) in base_query, where: comment.body == "comment")
      equivalent_query = Query.from([comments: comment] in base_query, where: comment.body == "comment")

      assert_same_query(equivalent_query, query)
    end

    test "binding/2 accepts dynamic binding names" do
      binding_name = :comments

      base_query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      query = DSL.from(binding(binding_name, comment) in base_query, where: comment.body == "comment")
      equivalent_query = Query.from([comments: comment] in base_query, where: comment.body == "comment")

      assert_same_query(equivalent_query, query)
    end
  end

  describe "binding_index/2" do
    test "returns the index for a named binding" do
      query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      assert DSL.binding_index(query, :self) == 0
      assert DSL.binding_index(query, :comments) == 1
    end

    test "raises when self is not named" do
      query = Query.from(post in Post)

      assert_raise ArgumentError, "query binding :self does not exist", fn ->
        DSL.binding_index(query, :self)
      end
    end

    test "raises when the named binding does not exist" do
      query = Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "query binding :comments does not exist", fn ->
        DSL.binding_index(query, :comments)
      end
    end
  end

  describe "binding_schema/1 and binding_schema/2" do
    test "returns the schema for root and joined bindings" do
      query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      assert DSL.binding_schema(query) == Post
      assert DSL.binding_schema(query, :self) == Post
      assert DSL.binding_schema(query, :comments) == Comment
      assert DSL.binding_schema(query, 1) == Comment
    end

    test "returns the root schema when self is not named" do
      query = Query.from(post in Post)

      assert DSL.binding_schema(query) == Post
    end

    test "returns the schema for nested association joins" do
      query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments,
          join: comment_post in assoc(comment, :post),
          as: :comment_post
        )

      assert DSL.binding_schema(query, :comment_post) == Post
    end

    test "returns the schema for direct schema joins" do
      query =
        Query.from(post in Post,
          as: :self,
          join: comment in Comment,
          as: :comments,
          on: comment.post_id == post.id
        )

      assert DSL.binding_schema(query, :comments) == Comment
    end

    test "uses the current scoped binding" do
      query =
        Query.from(post in Post,
          as: :self,
          join: comment in assoc(post, :comments),
          as: :comments
        )

      schema =
        with_ctx binding: :comments do
          DSL.binding_schema(query)
        end

      assert schema == Comment
    end

    test "raises for raw root sources" do
      query = Query.from(post in "patterns_posts", as: :self)

      assert_raise ArgumentError, "root query binding must be an Ecto schema source", fn ->
        DSL.binding_schema(query)
      end
    end

    test "raises for unnamed raw root sources" do
      query = Query.from(post in "patterns_posts")

      assert_raise ArgumentError, "root query binding must be an Ecto schema source", fn ->
        DSL.binding_schema(query)
      end
    end

    test "raises for raw join sources" do
      query =
        Query.from(post in Post,
          as: :self,
          join: comment in "patterns_comments",
          as: :comments,
          on: comment.post_id == post.id
        )

      assert_raise ArgumentError, "query binding at index 1 is not schema-backed", fn ->
        DSL.binding_schema(query, :comments)
      end
    end

    test "raises for non-schema-backed joins" do
      query =
        Post
        |> Query.from(as: :self)
        |> Query.join(
          :inner,
          [post],
          comment in subquery(Query.from(comment in Comment, select: %{post_id: comment.post_id})),
          as: :comments,
          on: comment.post_id == post.id
        )

      assert_raise ArgumentError, "query binding at index 1 is not schema-backed", fn ->
        DSL.binding_schema(query, :comments)
      end
    end

    test "raises for missing binding indexes" do
      query = Query.from(post in Post, as: :self)

      assert_raise ArgumentError, "query binding at index 2 does not exist", fn ->
        DSL.binding_schema(query, 2)
      end
    end
  end

  defp assert_same_query(%Query{} = ecto_query, %Query{} = patterns_query) do
    assert SQL.to_sql(:all, Repo, patterns_query) == SQL.to_sql(:all, Repo, ecto_query)
    assert Repo.all(patterns_query) == Repo.all(ecto_query)
  end
end
