defmodule Patterns.MemoTest do
  use ExUnit.Case, async: false

  alias Patterns.MemoTest.CachedPostsProxy
  alias Patterns.MemoTest.CoordinatedPostsProxy
  alias Patterns.MemoTest.DefaultPosts
  alias Patterns.MemoTest.DirtyPostsProxy
  alias Patterns.MemoTest.ExpiringPostsProxy
  alias Patterns.MemoTest.InvalidOptionsProxy
  alias Patterns.MemoTest.SelectivelyInvalidatingPostsProxy
  alias Patterns.MemoTest.SelfInvalidatingPostsProxy
  alias Patterns.MemoTest.StackedPostsProxy
  alias Patterns.MemoTest.StaleCoordinatedPostsProxy

  defmodule ObserveMiddleware do
    @moduledoc false
    @behaviour Patterns.Middleware

    use Patterns.Middleware

    @impl Patterns.Middleware
    def process([test_pid, _id] = args, resolution) do
      send(test_pid, :middleware_before)
      {result, resolution} = yield(args, resolution)
      send(test_pid, :middleware_after)

      {result, resolution}
    end
  end

  defmodule CachedPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: :infinity, proxy: CachedPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch, id})

      {:post, id}
    end
  end

  defmodule ExpiringPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: 50, proxy: ExpiringPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch, id})

      {:post, id, System.unique_integer([:positive])}
    end
  end

  defmodule DirtyPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: :infinity, dirty: true, proxy: DirtyPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch_started, self(), id})

      receive do
        :continue -> {:post, id}
      end
    end
  end

  defmodule CoordinatedPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: :infinity, dirty: false, proxy: CoordinatedPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch_started, self(), id})

      receive do
        :continue -> {:post, id, System.unique_integer([:positive])}
      end
    end
  end

  defmodule StaleCoordinatedPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: 500, dirty: false, proxy: StaleCoordinatedPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch_started, self(), id})

      receive do
        :continue -> {:post, id, System.unique_integer([:positive])}
      end
    end
  end

  defmodule DefaultPosts do
    @moduledoc false
    use Patterns.Memo

    @memo []
    def fetch(test_pid, id) do
      send(test_pid, {:fetch, id})

      {:post, id}
    end
  end

  defmodule SelfInvalidatingPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: :infinity, proxy: SelfInvalidatingPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch, id})
      :ok = invalidate()

      {:post, id, System.unique_integer([:positive])}
    end
  end

  defmodule SelectivelyInvalidatingPosts do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: :infinity, proxy: SelectivelyInvalidatingPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch, id})

      if id == 1 do
        :ok = invalidate()
      end

      {:post, id, System.unique_integer([:positive])}
    end
  end

  defmodule InvalidatesOutsideMemo do
    @moduledoc false
    use Patterns.Memo

    def fetch do
      invalidate()
    end
  end

  defmodule InvalidOptions do
    @moduledoc false
    use Patterns.Memo

    @memo ttl: -1, proxy: InvalidOptionsProxy
    def fetch do
      :ok
    end
  end

  defmodule InvalidDirtyOptions do
    @moduledoc false
    use Patterns.Memo

    @memo dirty: :yes, proxy: InvalidOptionsProxy
    def fetch do
      :ok
    end
  end

  defmodule InvalidProxyOptions do
    @moduledoc false
    use Patterns.Memo

    @memo proxy: {:bad, :proxy}
    def fetch do
      :ok
    end
  end

  defmodule StackedPosts do
    @moduledoc false
    use Patterns.Memo

    @middleware ObserveMiddleware
    @memo ttl: :infinity, proxy: StackedPostsProxy
    def fetch(test_pid, id) do
      send(test_pid, {:fetch, id})

      {:post, id}
    end
  end

  describe "@memo" do
    setup do
      for name <- [
            CachedPostsProxy,
            ExpiringPostsProxy,
            DirtyPostsProxy,
            CoordinatedPostsProxy,
            StaleCoordinatedPostsProxy,
            InvalidOptionsProxy,
            SelectivelyInvalidatingPostsProxy,
            SelfInvalidatingPostsProxy,
            StackedPostsProxy
          ] do
        start_supervised!({Patterns.Proxy.Supervisor, name: name}, id: name)
      end

      start_supervised!(Patterns.Proxy.Supervisor)

      :ok
    end

    test "caches by function arguments" do
      assert CachedPosts.fetch(self(), 1) == {:post, 1}
      assert_receive {:fetch, 1}

      assert CachedPosts.fetch(self(), 1) == {:post, 1}
      refute_receive {:fetch, 1}

      assert CachedPosts.fetch(self(), 2) == {:post, 2}
      assert_receive {:fetch, 2}
    end

    test "expires cached values after ttl" do
      first = ExpiringPosts.fetch(self(), 1)
      assert_receive {:fetch, 1}

      assert ExpiringPosts.fetch(self(), 1) == first
      refute_receive {:fetch, 1}

      Process.sleep(60)

      second = ExpiringPosts.fetch(self(), 1)
      assert_receive {:fetch, 1}

      assert second != first
    end

    test "dirty memoization may duplicate concurrent misses" do
      test_pid = self()
      first = Task.async(fn -> DirtyPosts.fetch(test_pid, 1) end)
      second = Task.async(fn -> DirtyPosts.fetch(test_pid, 1) end)

      assert_receive {:fetch_started, first_pid, 1}
      assert_receive {:fetch_started, second_pid, 1}

      send(first_pid, :continue)
      send(second_pid, :continue)

      assert Task.await(first) == {:post, 1}
      assert Task.await(second) == {:post, 1}
    end

    test "non-dirty memoization lets one concurrent miss win the cache" do
      test_pid = self()
      first = Task.async(fn -> CoordinatedPosts.fetch(test_pid, 1) end)
      second = Task.async(fn -> CoordinatedPosts.fetch(test_pid, 1) end)

      assert_receive {:fetch_started, first_pid, 1}
      assert_receive {:fetch_started, second_pid, 1}

      send(first_pid, :continue)
      send(second_pid, :continue)

      first_result = Task.await(first)

      assert Task.await(second) == first_result

      assert CoordinatedPosts.fetch(test_pid, 1) == first_result
      refute_receive {:fetch_started, _pid, 1}
    end

    test "non-dirty memoization coordinates per key" do
      test_pid = self()
      first = Task.async(fn -> CoordinatedPosts.fetch(test_pid, 1) end)
      second = Task.async(fn -> CoordinatedPosts.fetch(test_pid, 2) end)

      assert_receive {:fetch_started, first_pid, 1}
      assert_receive {:fetch_started, second_pid, 2}

      send(first_pid, :continue)
      send(second_pid, :continue)

      assert {:post, 1, _unique} = Task.await(first)
      assert {:post, 2, _unique} = Task.await(second)
    end

    test "non-dirty memoization lets one stale recomputation win the cache" do
      test_pid = self()
      first = Task.async(fn -> StaleCoordinatedPosts.fetch(test_pid, 1) end)

      assert_receive {:fetch_started, first_pid, 1}
      send(first_pid, :continue)
      first_value = Task.await(first)

      Process.sleep(600)

      second = Task.async(fn -> StaleCoordinatedPosts.fetch(test_pid, 1) end)
      third = Task.async(fn -> StaleCoordinatedPosts.fetch(test_pid, 1) end)

      assert_receive {:fetch_started, second_pid, 1}
      assert_receive {:fetch_started, third_pid, 1}

      send(second_pid, :continue)
      send(third_pid, :continue)

      second_value = Task.await(second)

      assert Task.await(third) == second_value
      assert second_value != first_value
    end

    test "runs as middleware with other middleware" do
      assert StackedPosts.fetch(self(), 1) == {:post, 1}
      assert_receive :middleware_before
      assert_receive {:fetch, 1}
      assert_receive :middleware_after

      assert StackedPosts.fetch(self(), 1) == {:post, 1}
      assert_receive :middleware_before
      refute_receive {:fetch, 1}
      assert_receive :middleware_after
    end

    test "uses default options" do
      assert DefaultPosts.fetch(self(), 1) == {:post, 1}
      assert_receive {:fetch, 1}

      assert DefaultPosts.fetch(self(), 1) == {:post, 1}
      refute_receive {:fetch, 1}
    end

    test "invalidates one argument list" do
      assert CachedPosts.fetch(self(), 1) == {:post, 1}
      assert_receive {:fetch, 1}

      assert CachedPosts.fetch(self(), 2) == {:post, 2}
      assert_receive {:fetch, 2}

      assert CachedPosts.fetch(self(), 1) == {:post, 1}
      refute_receive {:fetch, 1}

      assert CachedPosts.fetch(self(), 2) == {:post, 2}
      refute_receive {:fetch, 2}

      assert Patterns.Memo.invalidate(CachedPosts, :fetch, [self(), 1], proxy: CachedPostsProxy) == :ok

      assert CachedPosts.fetch(self(), 1) == {:post, 1}
      assert_receive {:fetch, 1}

      assert CachedPosts.fetch(self(), 2) == {:post, 2}
      refute_receive {:fetch, 2}
    end

    test "invalidate macro invalidates the current argument list" do
      first = SelfInvalidatingPosts.fetch(self(), 1)
      assert_receive {:fetch, 1}

      second = SelfInvalidatingPosts.fetch(self(), 1)
      assert_receive {:fetch, 1}

      assert second != first
    end

    test "invalidate macro leaves other argument lists cached" do
      assert {:post, 2, _unique} = SelectivelyInvalidatingPosts.fetch(self(), 2)
      assert_receive {:fetch, 2}

      assert {:post, 1, first_unique} = SelectivelyInvalidatingPosts.fetch(self(), 1)
      assert_receive {:fetch, 1}

      assert {:post, 1, second_unique} = SelectivelyInvalidatingPosts.fetch(self(), 1)
      assert_receive {:fetch, 1}

      assert second_unique != first_unique

      assert {:post, 2, _unique} = SelectivelyInvalidatingPosts.fetch(self(), 2)
      refute_receive {:fetch, 2}
    end

    test "invalidate macro requires a matching memoized function body" do
      assert_raise RuntimeError, ~r/matching memoized function body/, fn ->
        InvalidatesOutsideMemo.fetch()
      end
    end

    test "validates options when called" do
      assert_raise ArgumentError, ~r/expected :ttl/, fn ->
        InvalidOptions.fetch()
      end

      assert_raise ArgumentError, ~r/expected :dirty/, fn ->
        InvalidDirtyOptions.fetch()
      end

      assert_raise ArgumentError, ~r/expected :proxy/, fn ->
        InvalidProxyOptions.fetch()
      end
    end

    test "validates memo annotations at compile time" do
      assert_raise ArgumentError, ~r/expected @memo options/, fn ->
        Code.compile_string("""
        defmodule Patterns.MemoTest.InvalidMemoOptions do
          use Patterns.Memo

          @memo :oops
          def fetch do
            :ok
          end
        end
        """)
      end

      assert_raise ArgumentError, ~r/expected @memo options/, fn ->
        Code.compile_string("""
        defmodule Patterns.MemoTest.InvalidMemoListOptions do
          use Patterns.Memo

          @memo [:oops]
          def fetch do
            :ok
          end
        end
        """)
      end

      assert_raise ArgumentError, ~r/at most one @memo/, fn ->
        Code.compile_string("""
        defmodule Patterns.MemoTest.DuplicateMemoOptions do
          use Patterns.Memo

          @memo ttl: :infinity
          @memo dirty: false
          def fetch do
            :ok
          end
        end
        """)
      end
    end

    test "validates invalidation options" do
      assert_raise ArgumentError, ~r/expected :dirty/, fn ->
        Patterns.Memo.invalidate(CachedPosts, :fetch, [self(), 1], dirty: :yes)
      end

      assert_raise ArgumentError, ~r/expected :proxy/, fn ->
        Patterns.Memo.invalidate(CachedPosts, :fetch, [self(), 1], proxy: {:bad, :proxy})
      end
    end
  end
end
