defmodule Patterns.UtilsTest do
  use ExUnit.Case, async: true

  defmodule Source do
    @moduledoc false
    def zero, do: :ok
    def one(value), do: {:one, value}
    def two(left, right), do: {left, right}
    def calls_private, do: private()

    defp private, do: :hidden
  end

  defmodule Delegates do
    @moduledoc false
    import Patterns.Utils

    defdelegate_all(Source)
  end

  test "defdelegate_all delegates every public function" do
    assert Delegates.zero() == :ok
    assert Delegates.one(:value) == {:one, :value}
    assert Delegates.two(:left, :right) == {:left, :right}
    assert Delegates.calls_private() == :hidden
  end

  test "defdelegate_all ignores private functions" do
    refute function_exported?(Delegates, :private, 0)
  end
end
