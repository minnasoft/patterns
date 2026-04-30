defmodule Patterns.GuardsTest do
  use ExUnit.Case, async: true

  import Patterns.Guards

  describe "is_keyword/1" do
    test "matches empty lists" do
      assert keyword?([])
    end

    test "matches lists whose first element is an atom-key tuple" do
      assert keyword?([{:name, "Rin"}])
      assert keyword?(name: "Rin")
    end

    test "matches keyword-shaped lists without validating every element" do
      assert keyword?([{:name, "Rin"}, :bad])
      refute Keyword.keyword?([{:name, "Rin"}, :bad])
    end

    test "does not match maps" do
      refute keyword?(%{name: "Rin"})
    end

    test "does not match lists whose first element is not an atom-key tuple" do
      refute keyword?([{"name", "Rin"}])
      refute keyword?([:name])
      refute keyword?([{:name, "Rin", :extra}])
    end
  end

  defp keyword?(value) when is_keyword(value) do
    true
  end

  defp keyword?(_value) do
    false
  end
end
