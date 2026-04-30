defmodule Patterns.MiddlewareTest do
  use ExUnit.Case, async: true

  defmodule Blog.Middlewares.AuthorizeEditor do
    @moduledoc false
    @behaviour Patterns.Middleware

    @impl Patterns.Middleware
    def call(args, resolution) do
      send(self(), {:middleware, __MODULE__, args, resolution.module, resolution.function})

      Patterns.Middleware.yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.RecordAuditLog do
    @moduledoc false
    @behaviour Patterns.Middleware

    @impl Patterns.Middleware
    def call(args, resolution) do
      send(self(), {:middleware, __MODULE__, args, resolution.module, resolution.function})

      Patterns.Middleware.yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.NormalizePostTitle do
    @moduledoc false
    @behaviour Patterns.Middleware

    @impl Patterns.Middleware
    def call([attrs], resolution) do
      attrs = Map.update!(attrs, :title, &String.trim/1)

      Patterns.Middleware.yield([attrs], resolution)
    end
  end

  defmodule Blog do
    @moduledoc false

    use Patterns.Middleware

    alias Patterns.MiddlewareTest.Blog.Middlewares.AuthorizeEditor
    alias Patterns.MiddlewareTest.Blog.Middlewares.NormalizePostTitle
    alias Patterns.MiddlewareTest.Blog.Middlewares.RecordAuditLog

    @middleware RecordAuditLog
    def refresh_cache do
      :ok
    end

    @middleware [AuthorizeEditor, RecordAuditLog]
    def publish_post(post_id) do
      {:ok, {:published, post_id}}
    end

    @middleware AuthorizeEditor
    @middleware RecordAuditLog
    def delete_post(post_id) do
      {:ok, {:deleted, post_id}}
    end

    @middleware NormalizePostTitle
    def create_post(attrs) do
      {:ok, attrs}
    end

    @middleware RecordAuditLog
    def list_posts(scope, filters \\ [])

    def list_posts(:public, filters) do
      {:public_posts, filters}
    end

    def list_posts(scope, filters) do
      {:scoped_posts, scope, filters}
    end

    @middleware RecordAuditLog
    def rebuild_search_index(_repo, _opts) do
      :ok
    end

    def generate_preview(post_id) do
      build_preview(post_id)
    end

    @middleware RecordAuditLog
    defp build_preview(post_id) do
      {:ok, {:preview, post_id}}
    end

    def preview_status(post_id) do
      classify_preview(post_id)
    end

    @middleware RecordAuditLog
    defp classify_preview(:missing) do
      {:error, :missing}
    end

    defp classify_preview(post_id) do
      {:ok, {:preview, post_id}}
    end

    def list_preview_assets(scope, filters \\ []) do
      do_list_preview_assets(scope, filters)
    end

    @middleware RecordAuditLog
    defp do_list_preview_assets(scope, filters \\ [])

    defp do_list_preview_assets(:public, filters) do
      {:public_preview_assets, filters}
    end

    defp do_list_preview_assets(scope, filters) do
      {:scoped_preview_assets, scope, filters}
    end

    def rebuild_private_search_index(repo, opts) do
      do_rebuild_private_search_index(repo, opts)
    end

    @middleware RecordAuditLog
    defp do_rebuild_private_search_index(_repo, _opts) do
      :ok
    end
  end

  describe "@middleware" do
    test "defines a middleware behaviour" do
      assert Patterns.Middleware.behaviour_info(:callbacks) == [call: 2]
    end

    test "wraps a zero-arity function" do
      assert Blog.refresh_cache() == :ok

      assert_received {:middleware, Blog.Middlewares.RecordAuditLog, [], Blog, :refresh_cache}
    end

    test "accepts a middleware list" do
      assert Blog.publish_post(123) == {:ok, {:published, 123}}

      assert_receive {:middleware, Blog.Middlewares.AuthorizeEditor, [123], Blog, :publish_post}
      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [123], Blog, :publish_post}
    end

    test "accumulates repeated middleware attributes in source order" do
      assert Blog.delete_post(123) == {:ok, {:deleted, 123}}

      assert_receive {:middleware, Blog.Middlewares.AuthorizeEditor, [123], Blog, :delete_post}
      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [123], Blog, :delete_post}
    end

    test "allows middleware to change wrapped function arguments" do
      assert Blog.create_post(%{title: "  Hello Patterns  "}) == {:ok, %{title: "Hello Patterns"}}
    end

    test "wraps functions with default args and multiple clauses" do
      assert Blog.list_posts(:public) == {:public_posts, []}
      assert Blog.list_posts(:drafts, status: :review) == {:scoped_posts, :drafts, [status: :review]}

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:public, []], Blog, :list_posts}
      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:drafts, [status: :review]], Blog, :list_posts}
    end

    test "wraps functions with unused arguments" do
      assert Blog.rebuild_search_index(:repo, force: true) == :ok

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:repo, [force: true]], Blog, :rebuild_search_index}
    end

    test "wraps private functions" do
      assert Blog.generate_preview(123) == {:ok, {:preview, 123}}

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [123], Blog, :build_preview}
    end

    test "wraps private functions with multiple clauses" do
      assert Blog.preview_status(:missing) == {:error, :missing}
      assert Blog.preview_status(123) == {:ok, {:preview, 123}}

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:missing], Blog, :classify_preview}
      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [123], Blog, :classify_preview}
    end

    test "wraps private functions with default args and multiple clauses" do
      assert Blog.list_preview_assets(:public) == {:public_preview_assets, []}

      assert Blog.list_preview_assets(:drafts, status: :review) ==
               {:scoped_preview_assets, :drafts, [status: :review]}

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:public, []], Blog, :do_list_preview_assets}

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:drafts, [status: :review]], Blog,
                      :do_list_preview_assets}
    end

    test "wraps private functions with unused arguments" do
      assert Blog.rebuild_private_search_index(:repo, force: true) == :ok

      assert_receive {:middleware, Blog.Middlewares.RecordAuditLog, [:repo, [force: true]], Blog,
                      :do_rebuild_private_search_index}
    end
  end

  describe "run/4" do
    test "runs a stack without wrapping a function" do
      resolution = %Patterns.Middleware.Resolution{
        module: __MODULE__,
        function: :manual_publish,
        arity: 1,
        args: [123],
        middleware: []
      }

      result =
        Patterns.Middleware.run([Blog.Middlewares.RecordAuditLog], [123], resolution, fn input, resolution ->
          {:done, input, resolution.function}
        end)

      assert result == {:done, [123], :manual_publish}
      assert_received {:middleware, Blog.Middlewares.RecordAuditLog, [123], __MODULE__, :manual_publish}
    end
  end
end
