defmodule Patterns.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Patterns.Middleware.Resolution

  defmodule Blog.Middlewares.AuthorizeEditor do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      send(self(), {:middleware, self(), __MODULE__, args, resolution.module, resolution.function})

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.RecordAuditLog do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      send(self(), {:middleware, self(), __MODULE__, args, resolution.module, resolution.function})

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.RecordAuditLogWithOpts do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      send(self(), {:middleware_opts, __MODULE__, args, resolution.opts})

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.AssertOptsAfterYield do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      send(self(), {:middleware_opts_before_yield, resolution.opts})

      {result, resolution} = yield(args, resolution)

      send(self(), {:middleware_opts_after_yield, resolution.opts})

      {result, resolution}
    end
  end

  defmodule Blog.Middlewares.AssertEmptyOpts do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      send(self(), {:middleware_opts, __MODULE__, args, resolution.opts})

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.NormalizePostTitle do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process([attrs], resolution) do
      attrs = Map.update!(attrs, :title, &String.trim/1)

      yield([attrs], resolution)
    end
  end

  defmodule Blog.Middlewares.StoreDraftRemotely do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      resolution =
        put_super(resolution, fn args, resolution ->
          {:remote, resolution.function, args}
        end)

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.MarkSavedPost do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      resolution =
        update_super(resolution, fn super ->
          fn args, resolution ->
            {:ok, post} = super.(args, resolution)

            {:ok, Map.update(post, :events, [:saved], &[:saved | &1])}
          end
        end)

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.IndexSavedPost do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      resolution =
        update_super(resolution, fn super ->
          fn args, resolution ->
            {:ok, post} = super.(args, resolution)

            {:ok, Map.update(post, :events, [:indexed], &[:indexed | &1])}
          end
        end)

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.ReturnMissingPost do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process([:missing], resolution) do
      {{:error, :missing}, resolution}
    end

    def process(args, resolution) do
      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.ReadPaginationResolution do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      {result, resolution} = yield(args, resolution)

      if get_private(resolution, :paginated?) do
        {{:paginated, result}, resolution}
      else
        {result, resolution}
      end
    end
  end

  defmodule Blog.Middlewares.MarkPaginationResolution do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      {result, resolution} = yield(args, resolution)

      {result, put_private(resolution, :paginated?, true)}
    end
  end

  defmodule Blog.Middlewares.AssertOriginalArgs do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(args, resolution) do
      send(self(), {:original_args, resolution.args})

      yield(args, resolution)
    end
  end

  defmodule Blog.Middlewares.DropPostArgs do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process(_args, resolution) do
      yield([], resolution)
    end
  end

  defmodule Blog do
    @moduledoc false

    use Patterns.Middleware

    alias Patterns.MiddlewareTest.Blog.Middlewares.AssertEmptyOpts
    alias Patterns.MiddlewareTest.Blog.Middlewares.AssertOptsAfterYield
    alias Patterns.MiddlewareTest.Blog.Middlewares.AssertOriginalArgs
    alias Patterns.MiddlewareTest.Blog.Middlewares.AuthorizeEditor
    alias Patterns.MiddlewareTest.Blog.Middlewares.DropPostArgs
    alias Patterns.MiddlewareTest.Blog.Middlewares.IndexSavedPost
    alias Patterns.MiddlewareTest.Blog.Middlewares.MarkPaginationResolution
    alias Patterns.MiddlewareTest.Blog.Middlewares.MarkSavedPost
    alias Patterns.MiddlewareTest.Blog.Middlewares.NormalizePostTitle
    alias Patterns.MiddlewareTest.Blog.Middlewares.ReadPaginationResolution
    alias Patterns.MiddlewareTest.Blog.Middlewares.RecordAuditLog
    alias Patterns.MiddlewareTest.Blog.Middlewares.RecordAuditLogWithOpts
    alias Patterns.MiddlewareTest.Blog.Middlewares.ReturnMissingPost
    alias Patterns.MiddlewareTest.Blog.Middlewares.StoreDraftRemotely

    @middleware RecordAuditLog
    def refresh_cache do
      :ok
    end

    @middleware [AuthorizeEditor, RecordAuditLog]
    def publish_post(post_id) do
      {:ok, {:published, post_id}}
    end

    @middleware {RecordAuditLogWithOpts, event: :archive_post}
    def archive_post(post_id) do
      {:ok, {:archived, post_id}}
    end

    @middleware [AuthorizeEditor, {RecordAuditLogWithOpts, event: :feature_post}]
    def feature_post(post_id) do
      {:ok, {:featured, post_id}}
    end

    @middleware {AssertOptsAfterYield, event: :outer}
    @middleware {RecordAuditLogWithOpts, event: :inner}
    def schedule_post(post_id) do
      {:ok, {:scheduled, post_id}}
    end

    @middleware {RecordAuditLogWithOpts, event: :promote_post}
    @middleware AssertEmptyOpts
    def promote_post(post_id) do
      {:ok, {:promoted, post_id}}
    end

    @middleware AuthorizeEditor
    @middleware RecordAuditLog
    def delete_post(post_id) do
      {:ok, {:deleted, post_id}}
    end

    @middleware NormalizePostTitle
    @middleware AssertOriginalArgs
    def create_post(attrs) do
      {:ok, attrs}
    end

    @middleware StoreDraftRemotely
    def create_draft(attrs) do
      {:ok, attrs}
    end

    @middleware MarkSavedPost
    def save_post(attrs) do
      {:ok, attrs}
    end

    @middleware MarkSavedPost
    @middleware IndexSavedPost
    def save_and_index_post(attrs) do
      {:ok, attrs}
    end

    @middleware DropPostArgs
    def save_without_args(attrs) do
      {:ok, attrs}
    end

    @middleware ReturnMissingPost
    def fetch_post(:published) do
      {:ok, :published}
    end

    @middleware ReadPaginationResolution
    @middleware MarkPaginationResolution
    def list_paginated_posts do
      [:post]
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
      assert {:process, 2} in Patterns.Middleware.behaviour_info(:callbacks)
    end

    test "wraps a zero-arity function" do
      assert Blog.refresh_cache() == :ok

      assert_received {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [], Blog, :refresh_cache}
    end

    test "accepts a middleware list" do
      assert Blog.publish_post(123) == {:ok, {:published, 123}}

      assert_receive {:middleware, first_pid, Blog.Middlewares.AuthorizeEditor, [123], Blog, :publish_post}
      assert_receive {:middleware, ^first_pid, Blog.Middlewares.RecordAuditLog, [123], Blog, :publish_post}
    end

    test "accepts middleware entries with options" do
      assert Blog.archive_post(123) == {:ok, {:archived, 123}}

      assert_receive {:middleware_opts, Blog.Middlewares.RecordAuditLogWithOpts, [123], event: :archive_post}
    end

    test "accepts option entries inside middleware lists" do
      assert Blog.feature_post(123) == {:ok, {:featured, 123}}

      assert_receive {:middleware, _pid, Blog.Middlewares.AuthorizeEditor, [123], Blog, :feature_post}
      assert_receive {:middleware_opts, Blog.Middlewares.RecordAuditLogWithOpts, [123], event: :feature_post}
    end

    test "restores middleware options after yielding" do
      assert Blog.schedule_post(123) == {:ok, {:scheduled, 123}}

      assert_receive {:middleware_opts_before_yield, event: :outer}
      assert_receive {:middleware_opts, Blog.Middlewares.RecordAuditLogWithOpts, [123], event: :inner}
      assert_receive {:middleware_opts_after_yield, event: :outer}
    end

    test "uses empty options for bare entries after option entries" do
      assert Blog.promote_post(123) == {:ok, {:promoted, 123}}

      assert_receive {:middleware_opts, Blog.Middlewares.RecordAuditLogWithOpts, [123], event: :promote_post}
      assert_receive {:middleware_opts, Blog.Middlewares.AssertEmptyOpts, [123], []}
    end

    test "accumulates repeated middleware attributes in source order" do
      assert Blog.delete_post(123) == {:ok, {:deleted, 123}}

      assert_receive {:middleware, first_pid, Blog.Middlewares.AuthorizeEditor, [123], Blog, :delete_post}
      assert_receive {:middleware, ^first_pid, Blog.Middlewares.RecordAuditLog, [123], Blog, :delete_post}
    end

    test "allows middleware to change wrapped function arguments" do
      assert Blog.create_post(%{title: "  Hello Patterns  "}) == {:ok, %{title: "Hello Patterns"}}

      assert_received {:original_args, [%{title: "  Hello Patterns  "}]}
    end

    test "allows middleware to replace super" do
      assert Blog.create_draft(%{title: "Draft"}) == {:remote, :create_draft, [%{title: "Draft"}]}
    end

    test "allows middleware to wrap super" do
      assert Blog.save_post(%{title: "Saved"}) == {:ok, %{title: "Saved", events: [:saved]}}
    end

    test "allows stacked middleware to wrap super" do
      assert Blog.save_and_index_post(%{title: "Saved"}) ==
               {:ok, %{title: "Saved", events: [:indexed, :saved]}}
    end

    test "raises when middleware yields arguments that do not match the wrapped arity" do
      assert_raise MatchError, fn ->
        Blog.save_without_args(%{title: "Saved"})
      end
    end

    test "runs middleware before original function clauses match" do
      assert Blog.fetch_post(:published) == {:ok, :published}
      assert Blog.fetch_post(:missing) == {:error, :missing}
    end

    test "allows upstream middleware to inspect downstream resolution changes" do
      assert Blog.list_paginated_posts() == {:paginated, [:post]}
    end

    test "wraps functions with default args and multiple clauses" do
      assert Blog.list_posts(:public) == {:public_posts, []}
      assert Blog.list_posts(:drafts, status: :review) == {:scoped_posts, :drafts, [status: :review]}

      draft_args = [:drafts, [status: :review]]

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [:public, []], Blog, :list_posts}
      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, ^draft_args, Blog, :list_posts}
    end

    test "wraps functions with unused arguments" do
      assert Blog.rebuild_search_index(:repo, force: true) == :ok

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [:repo, [force: true]], Blog,
                      :rebuild_search_index}
    end

    test "wraps private functions" do
      assert Blog.generate_preview(123) == {:ok, {:preview, 123}}

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [123], Blog, :build_preview}
    end

    test "wraps private functions with multiple clauses" do
      assert Blog.preview_status(:missing) == {:error, :missing}
      assert Blog.preview_status(123) == {:ok, {:preview, 123}}

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [:missing], Blog, :classify_preview}
      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [123], Blog, :classify_preview}
    end

    test "wraps private functions with default args and multiple clauses" do
      assert Blog.list_preview_assets(:public) == {:public_preview_assets, []}

      assert Blog.list_preview_assets(:drafts, status: :review) ==
               {:scoped_preview_assets, :drafts, [status: :review]}

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [:public, []], Blog, :do_list_preview_assets}

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [:drafts, [status: :review]], Blog,
                      :do_list_preview_assets}
    end

    test "wraps private functions with unused arguments" do
      assert Blog.rebuild_private_search_index(:repo, force: true) == :ok

      assert_receive {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [:repo, [force: true]], Blog,
                      :do_rebuild_private_search_index}
    end
  end

  describe "run/4" do
    # NOTE: More complex stack behavior is indirectly tested through the
    # annotation tests above. These tests keep run/4 focused on its direct API.
    test "calls super without middleware" do
      resolution = %Resolution{
        module: __MODULE__,
        function: :manual_publish,
        arity: 1,
        args: [123],
        middleware: []
      }

      {result, resolution} =
        Patterns.Middleware.run([], [123], resolution, fn input, resolution ->
          {:done, input, resolution.function}
        end)

      assert result == {:done, [123], :manual_publish}
      assert resolution.function == :manual_publish
    end

    test "runs a stack without wrapping a function" do
      resolution = %Resolution{
        module: __MODULE__,
        function: :manual_publish,
        arity: 1,
        args: [123],
        middleware: []
      }

      {result, resolution} =
        Patterns.Middleware.run([Blog.Middlewares.RecordAuditLog], [123], resolution, fn input, resolution ->
          {:done, input, resolution.function}
        end)

      assert result == {:done, [123], :manual_publish}
      assert resolution.function == :manual_publish
      assert_received {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [123], __MODULE__, :manual_publish}
    end

    test "accepts a single middleware module" do
      resolution = %Resolution{
        module: __MODULE__,
        function: :manual_publish,
        arity: 1,
        args: [123],
        middleware: []
      }

      {result, resolution} =
        Patterns.Middleware.run(Blog.Middlewares.RecordAuditLog, [123], resolution, fn input, resolution ->
          {:done, input, resolution.function}
        end)

      assert result == {:done, [123], :manual_publish}
      assert resolution.function == :manual_publish
      assert_received {:middleware, _pid, Blog.Middlewares.RecordAuditLog, [123], __MODULE__, :manual_publish}
    end

    test "accepts middleware entries with options" do
      resolution = %Resolution{
        module: __MODULE__,
        function: :manual_archive,
        arity: 1,
        args: [123],
        middleware: []
      }

      {result, resolution} =
        Patterns.Middleware.run(
          {Blog.Middlewares.RecordAuditLogWithOpts, event: :manual_archive},
          [123],
          resolution,
          fn input, resolution ->
            {:done, input, resolution.function}
          end
        )

      assert result == {:done, [123], :manual_archive}
      assert resolution.function == :manual_archive
      assert_received {:middleware_opts, Blog.Middlewares.RecordAuditLogWithOpts, [123], event: :manual_archive}
    end

    test "returns resolution changes from middleware" do
      resolution = %Resolution{
        module: __MODULE__,
        function: :manual_paginate,
        arity: 0,
        args: [],
        middleware: []
      }

      {result, resolution} =
        Patterns.Middleware.run(Blog.Middlewares.MarkPaginationResolution, [], resolution, fn _input, _resolution ->
          [:post]
        end)

      assert result == [:post]
      assert Patterns.Middleware.get_private(resolution, :paginated?) == true
    end
  end

  describe "yield/2" do
    test "raises when called without run/4 installing super" do
      assert_raise KeyError, fn ->
        Patterns.Middleware.yield([], %Resolution{})
      end
    end
  end

  describe "get_super/1" do
    test "returns the current super function" do
      resolution = %Resolution{}

      initial_super = fn input, _resolution -> {:initial, input} end

      resolution = Patterns.Middleware.put_super(resolution, initial_super)

      assert Patterns.Middleware.get_super(resolution).(:input, resolution) == {:initial, :input}
    end
  end

  describe "put_super/2" do
    test "replaces the super function" do
      initial_super = fn input, _resolution -> {:initial, input} end
      replacement_super = fn input, _resolution -> {:replacement, input} end

      resolution =
        %Resolution{}
        |> Patterns.Middleware.put_super(initial_super)
        |> Patterns.Middleware.put_super(replacement_super)

      assert Patterns.Middleware.get_super(resolution).(:input, resolution) == {:replacement, :input}
    end
  end

  describe "update_super/2" do
    test "wraps the current super function" do
      initial_super = fn input, _resolution -> {:initial, input} end

      resolution = Patterns.Middleware.put_super(%Resolution{}, initial_super)

      resolution =
        Patterns.Middleware.update_super(resolution, fn super ->
          fn input, resolution ->
            {:wrapped, super.(input, resolution)}
          end
        end)

      assert Patterns.Middleware.get_super(resolution).(:input, resolution) == {:wrapped, {:initial, :input}}
    end

    test "raises when no super function exists" do
      assert_raise KeyError, fn ->
        Patterns.Middleware.update_super(%Resolution{}, fn super ->
          fn input, resolution ->
            {:wrapped, super.(input, resolution)}
          end
        end)
      end
    end
  end

  describe "get_private/2" do
    test "returns nil when the key is missing" do
      resolution = %Resolution{}

      assert Patterns.Middleware.get_private(resolution, :attempts) == nil
    end
  end

  describe "get_private/3" do
    test "returns the default when the key is missing" do
      resolution = %Resolution{}

      assert Patterns.Middleware.get_private(resolution, :attempts, 0) == 0
    end

    test "returns the stored value when the key exists" do
      resolution = Patterns.Middleware.put_private(%Resolution{}, :attempts, 1)

      assert Patterns.Middleware.get_private(resolution, :attempts, 0) == 1
    end
  end

  describe "put_private/3" do
    test "stores private values" do
      resolution = %Resolution{}

      resolution = Patterns.Middleware.put_private(resolution, :attempts, 1)

      assert Patterns.Middleware.get_private(resolution, :attempts) == 1
    end
  end

  describe "update_private/4" do
    test "stores the default when the key is missing" do
      resolution = Patterns.Middleware.update_private(%Resolution{}, :attempts, 1, &(&1 + 1))

      assert Patterns.Middleware.get_private(resolution, :attempts) == 1
    end

    test "updates private values" do
      resolution = Patterns.Middleware.put_private(%Resolution{}, :attempts, 1)

      resolution = Patterns.Middleware.update_private(resolution, :attempts, 0, &(&1 + 1))

      assert Patterns.Middleware.get_private(resolution, :attempts) == 2
    end
  end

  describe "delete_private/2" do
    test "ignores missing keys" do
      resolution = Patterns.Middleware.delete_private(%Resolution{}, :attempts)

      assert Patterns.Middleware.get_private(resolution, :attempts) == nil
    end

    test "deletes private values" do
      resolution = Patterns.Middleware.put_private(%Resolution{}, :attempts, 1)

      resolution = Patterns.Middleware.delete_private(resolution, :attempts)

      assert Patterns.Middleware.get_private(resolution, :attempts) == nil
    end
  end

  describe "__before_compile__/1" do
    test "rejects conflicting middleware stacks for the same function" do
      module = Module.concat(__MODULE__, "ConflictingMiddleware#{System.unique_integer([:positive])}")

      quoted =
        quote do
          defmodule unquote(module) do
            use Patterns.Middleware

            alias Patterns.MiddlewareTest.Blog.Middlewares.AuthorizeEditor
            alias Patterns.MiddlewareTest.Blog.Middlewares.RecordAuditLog

            @middleware AuthorizeEditor
            def publish(:draft) do
              :draft
            end

            @middleware RecordAuditLog
            def publish(:public) do
              :public
            end
          end
        end

      assert_raise CompileError, ~r/conflicting @middleware stacks.*publish\/1/, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
