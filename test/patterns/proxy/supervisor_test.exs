defmodule Patterns.Proxy.SupervisorTest do
  use ExUnit.Case, async: false

  describe "start_link/1" do
    test "starts with the default name" do
      assert {:ok, pid} = start_supervised(Patterns.Proxy.Supervisor)

      assert Process.whereis(Patterns.Proxy.Supervisor) == pid

      proxy = Patterns.Proxy.ensure!(Patterns.Proxy.Supervisor, {:blog, :fetch_post, 1})

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      assert Patterns.Proxy.get(proxy, :post) == {:ok, %{id: 1}}
    end

    test "starts with a custom name" do
      name = supervisor_name()
      assert {:ok, pid} = start_supervised({Patterns.Proxy.Supervisor, name: name})

      assert Process.whereis(name) == pid

      proxy = Patterns.Proxy.ensure!(name, {:blog, :fetch_post, 1})

      assert Patterns.Proxy.put(proxy, :post, %{id: 1}) == :ok
      assert Patterns.Proxy.get(proxy, :post) == {:ok, %{id: 1}}
    end
  end

  defp supervisor_name do
    Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
  end
end
