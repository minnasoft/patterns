defmodule Patterns.ProxyTest do
  use ExUnit.Case, async: true
  use Patterns.Proxy

  describe "ensure/3" do
    test "starts a proxy under a supervisor" do
      supervisor = start_supervisor!()

      assert {:ok, proxy} = Patterns.Proxy.ensure(supervisor, {:blog, :fetch_post, 1})

      assert proxy.scope == {:blog, :fetch_post, 1}

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      assert Patterns.Proxy.get(proxy, :post) == {:ok, %{id: 1}}
    end

    test "returns the existing proxy for a scope" do
      supervisor = start_supervisor!()

      assert {:ok, first_proxy} = Patterns.Proxy.ensure(supervisor, {:blog, :fetch_post, 1})
      assert {:ok, second_proxy} = Patterns.Proxy.ensure(supervisor, {:blog, :fetch_post, 1})

      assert second_proxy == first_proxy

      assert Patterns.Proxy.put(first_proxy, :post, %{id: 1}) == :ok
      assert Patterns.Proxy.get(second_proxy, :post) == {:ok, %{id: 1}}
    end

    test "returns the existing proxy for concurrent callers" do
      supervisor = start_supervisor!()
      test_pid = self()
      scope = {:blog, :fetch_post, 1}

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            send(test_pid, :ready)

            receive do
              :go -> :ok
            end

            {:ok, proxy} = Patterns.Proxy.ensure(supervisor, scope)
            proxy
          end)
        end

      for _task <- tasks do
        assert_receive :ready
      end

      for task <- tasks do
        send(task.pid, :go)
      end

      proxies = Enum.map(tasks, &Task.await/1)

      assert proxies |> Enum.uniq() |> length() == 1
    end

    test "isolates state for different scopes" do
      supervisor = start_supervisor!()

      first_proxy = Patterns.Proxy.ensure!(supervisor, {:blog, :fetch_post, 1})
      second_proxy = Patterns.Proxy.ensure!(supervisor, {:blog, :fetch_comment, 1})

      assert Patterns.Proxy.put(first_proxy, :record, %{id: 1}) == :ok
      assert Patterns.Proxy.put(second_proxy, :record, %{id: 2}) == :ok

      assert Patterns.Proxy.get(first_proxy, :record) == {:ok, %{id: 1}}
      assert Patterns.Proxy.get(second_proxy, :record) == {:ok, %{id: 2}}
    end
  end

  describe "ensure!/3" do
    test "returns the proxy" do
      supervisor = start_supervisor!()

      proxy = Patterns.Proxy.ensure!(supervisor, {:blog, :fetch_post, 1})

      assert proxy.scope == {:blog, :fetch_post, 1}
    end

    test "raises when the supervisor is not started" do
      supervisor = Module.concat(__MODULE__, "MissingSupervisor#{System.unique_integer([:positive])}")

      assert Patterns.Proxy.ensure(supervisor, {:blog, :fetch_post, 1}) == {:error, :not_started}

      assert_raise RuntimeError, ~r/could not start proxy/, fn ->
        Patterns.Proxy.ensure!(supervisor, {:blog, :fetch_post, 1})
      end
    end
  end

  describe "with_proxy/4" do
    test "calls the function with the proxy" do
      supervisor = start_supervisor!()

      result =
        with_proxy supervisor, {:blog, :fetch_post, 1}, [] do
          proxy ->
            {:ok, proxy.scope}
        end

      assert result == {:ok, {:blog, :fetch_post, 1}}
    end

    test "supports shorthand block syntax" do
      supervisor = start_supervisor!()
      scope = {:blog, :fetch_post, 1}

      result =
        with_proxy supervisor, scope do
          proxy ->
            Patterns.Proxy.put(proxy, :post, %{id: 1})
            Patterns.Proxy.get(proxy, :post)
        end

      assert result == {:ok, %{id: 1}}
    end

    test "supports guarded block syntax" do
      supervisor = start_supervisor!()
      dirty? = dirty_option()

      result =
        with_proxy supervisor, {:blog, :fetch_post, 1}, [] do
          proxy when dirty? ->
            {:dirty, proxy.scope}

          proxy ->
            {:clean, proxy.scope}
        end

      assert result == {:dirty, {:blog, :fetch_post, 1}}
    end

    test "imports only with_proxy syntax" do
      assert __ENV__.functions |> Keyword.get(Patterns.Proxy, []) |> Keyword.keys() == []
      assert :with_proxy in (__ENV__.macros |> Keyword.fetch!(Patterns.Proxy.DSL) |> Keyword.keys())
    end

    test "starts lazily and reuses existing state" do
      supervisor = start_supervisor!()
      scope = {:blog, :fetch_post, 1}

      assert Patterns.Proxy.with_proxy(supervisor, scope, [], fn proxy ->
               Patterns.Proxy.put(proxy, :post, %{id: 1})
             end) == :ok

      assert Patterns.Proxy.with_proxy(supervisor, scope, [], fn proxy ->
               Patterns.Proxy.get(proxy, :post)
             end) == {:ok, %{id: 1}}
    end

    test "propagates callback errors" do
      supervisor = start_supervisor!()

      assert_raise RuntimeError, "boom", fn ->
        Patterns.Proxy.with_proxy(supervisor, {:blog, :fetch_post, 1}, [], fn _proxy ->
          raise "boom"
        end)
      end
    end

    test "raises when the supervisor is not started" do
      supervisor = Module.concat(__MODULE__, "MissingSupervisor#{System.unique_integer([:positive])}")

      assert_raise RuntimeError, ~r/could not start proxy/, fn ->
        Patterns.Proxy.with_proxy(supervisor, {:blog, :fetch_post, 1}, [], fn proxy ->
          proxy
        end)
      end
    end
  end

  describe "get/3" do
    test "returns error for missing keys" do
      proxy = start_proxy!()

      assert Patterns.Proxy.get(proxy, :missing) == :error
    end

    test "returns stored values" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok

      assert Patterns.Proxy.get(proxy, :post) == {:ok, %{id: 1}}
    end

    test "accepts dirty for symmetry" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok

      assert Patterns.Proxy.get(proxy, :post, dirty: true) == {:ok, %{id: 1}}
    end
  end

  describe "put/4" do
    test "stores values through the proxy process" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}, dirty: false) == :ok

      assert Patterns.Proxy.get(proxy, :post) == {:ok, %{id: 1}}
    end

    test "stores dirty values directly" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}, dirty: true) == :ok

      assert Patterns.Proxy.get(proxy, :post) == {:ok, %{id: 1}}
    end
  end

  describe "update/5" do
    test "stores the initial value through the proxy process" do
      proxy = start_proxy!()

      value = Patterns.Proxy.update(proxy, :count, 0, &(&1 + 1), dirty: false)

      assert value == 1
      assert Patterns.Proxy.get(proxy, :count) == {:ok, 1}
    end

    test "updates existing values through the proxy process" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :count, 1) == :ok

      value = Patterns.Proxy.update(proxy, :count, 0, &(&1 + 1), dirty: false)

      assert value == 2
      assert Patterns.Proxy.get(proxy, :count) == {:ok, 2}
    end

    test "updates dirty values directly" do
      proxy = start_proxy!()

      value = Patterns.Proxy.update(proxy, :count, 0, &(&1 + 1), dirty: true)

      assert value == 1
      assert Patterns.Proxy.get(proxy, :count) == {:ok, 1}
    end

    test "dirty updates can overwrite each other" do
      proxy = start_proxy!()
      test_pid = self()
      assert Patterns.Proxy.put(proxy, :count, 0) == :ok

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Patterns.Proxy.update(
              proxy,
              :count,
              0,
              fn count ->
                send(test_pid, {:read_count, self(), count})

                receive do
                  :continue -> count + 1
                end
              end,
              dirty: true
            )
          end)
        end

      assert_receive {:read_count, first_pid, 0}
      assert_receive {:read_count, second_pid, 0}

      send(first_pid, :continue)
      send(second_pid, :continue)

      assert Enum.map(tasks, &Task.await/1) == [1, 1]
      assert Patterns.Proxy.get(proxy, :count) == {:ok, 1}
    end

    test "serializes concurrent non-dirty updates" do
      proxy = start_proxy!()
      test_pid = self()

      for _ <- 1..50 do
        Task.start_link(fn ->
          Patterns.Proxy.update(
            proxy,
            :count,
            0,
            &(&1 + 1),
            dirty: false
          )

          send(test_pid, :updated)
        end)
      end

      for _ <- 1..50 do
        assert_receive :updated
      end

      assert Patterns.Proxy.get(proxy, :count) == {:ok, 50}
    end
  end

  describe "delete/3" do
    test "deletes values through the proxy process" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      assert Patterns.Proxy.delete(proxy, :post, dirty: false) == :ok

      assert Patterns.Proxy.get(proxy, :post) == :error
    end

    test "deletes dirty values directly" do
      proxy = start_proxy!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      assert Patterns.Proxy.delete(proxy, :post, dirty: true) == :ok

      assert Patterns.Proxy.get(proxy, :post) == :error
    end
  end

  describe "ephemeral handles" do
    test "reads use the cached handle after restart" do
      {supervisor, proxy} = start_proxy_with_supervisor!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      restart_proxy!(supervisor, proxy.scope)

      assert catch_error(Patterns.Proxy.get(proxy, :post))
    end

    test "dirty operations use the cached handle after restart" do
      {supervisor, proxy} = start_proxy_with_supervisor!()

      restart_proxy!(supervisor, proxy.scope)

      assert catch_error(Patterns.Proxy.put(proxy, :post, %{id: 1}, dirty: true))
      assert catch_error(Patterns.Proxy.update(proxy, :count, 0, &(&1 + 1), dirty: true))
      assert catch_error(Patterns.Proxy.delete(proxy, :post, dirty: true))
    end

    test "non-dirty operations re-resolve after restart" do
      {supervisor, proxy} = start_proxy_with_supervisor!()

      restart_proxy!(supervisor, proxy.scope)

      assert Patterns.Proxy.put(proxy, :count, 1, dirty: false) == :ok
      assert Patterns.Proxy.update(proxy, :count, 0, &(&1 + 1), dirty: false) == 2
      assert Patterns.Proxy.delete(proxy, :count, dirty: false) == :ok

      fresh_proxy = Patterns.Proxy.ensure!(supervisor, proxy.scope)

      assert Patterns.Proxy.get(fresh_proxy, :count) == :error
    end

    test "state is lost after restart" do
      {supervisor, proxy} = start_proxy_with_supervisor!()

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      restart_proxy!(supervisor, proxy.scope)

      fresh_proxy = Patterns.Proxy.ensure!(supervisor, proxy.scope)

      assert Patterns.Proxy.get(fresh_proxy, :post) == :error
    end
  end

  defp start_supervisor! do
    name = Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
    start_supervised!({Patterns.Proxy.Supervisor, name: name})

    name
  end

  defp start_proxy! do
    {_supervisor, proxy} = start_proxy_with_supervisor!()

    proxy
  end

  defp start_proxy_with_supervisor! do
    supervisor = start_supervisor!()
    scope = {:blog, :fetch_post, 1}

    {supervisor, Patterns.Proxy.ensure!(supervisor, scope)}
  end

  defp restart_proxy!(supervisor, scope) do
    pid = proxy_pid!(supervisor, scope)

    Process.exit(pid, :kill)

    wait_until(fn ->
      case Registry.lookup(Patterns.Proxy.Supervisor.registry(supervisor), scope) do
        [{new_pid, _table}] when new_pid != pid -> true
        _entries -> false
      end
    end)
  end

  defp proxy_pid!(supervisor, scope) do
    [{pid, _table}] = Registry.lookup(Patterns.Proxy.Supervisor.registry(supervisor), scope)

    pid
  end

  defp dirty_option do
    true
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("timed out waiting for proxy restart")
  end
end
