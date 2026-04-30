defmodule Patterns.UtilsTest do
  use ExUnit.Case, async: true

  import Patterns.Utils, only: [with_ctx: 2]

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

  describe "defdelegate_all/1" do
    test "delegates every public function" do
      assert Delegates.zero() == :ok
      assert Delegates.one(:value) == {:one, :value}
      assert Delegates.two(:left, :right) == {:left, :right}
      assert Delegates.calls_private() == :hidden
    end

    test "ignores private functions" do
      refute function_exported?(Delegates, :private, 0)
    end
  end

  describe "with_ctx/2" do
    test "sets and restores scoped context" do
      assert is_nil(Patterns.Utils.ctx(:binding))

      result =
        with_ctx binding: :references do
          assert Patterns.Utils.ctx(:binding) == :references

          inner_result =
            with_ctx binding: :target do
              Patterns.Utils.ctx(:binding)
            end

          assert inner_result == :target
          assert Patterns.Utils.ctx(:binding) == :references

          inner_result
        end

      assert result == :target
      assert is_nil(Patterns.Utils.ctx(:binding))
    end

    test "merges nested context without removing sibling keys" do
      assert is_nil(Patterns.Utils.ctx(:binding))
      assert is_nil(Patterns.Utils.ctx(:schema))

      with_ctx binding: :references, schema: Source do
        assert Patterns.Utils.ctx(:binding) == :references
        assert Patterns.Utils.ctx(:schema) == Source

        with_ctx binding: :target do
          assert Patterns.Utils.ctx(:binding) == :target
          assert Patterns.Utils.ctx(:schema) == Source
        end

        assert Patterns.Utils.ctx(:binding) == :references
        assert Patterns.Utils.ctx(:schema) == Source
      end

      assert is_nil(Patterns.Utils.ctx(:binding))
      assert is_nil(Patterns.Utils.ctx(:schema))
    end

    test "accepts map context" do
      with_ctx %{binding: :references} do
        assert Patterns.Utils.ctx(:binding) == :references
      end

      assert is_nil(Patterns.Utils.ctx(:binding))
    end

    test "restores context when the block raises" do
      assert_raise RuntimeError, "boom", fn ->
        with_ctx binding: :references do
          raise "boom"
        end
      end

      assert is_nil(Patterns.Utils.ctx(:binding))
    end

    test "restores context when the block throws" do
      assert catch_throw(
               with_ctx binding: :references do
                 throw(:boom)
               end
             ) == :boom

      assert is_nil(Patterns.Utils.ctx(:binding))
    end

    test "restores context when the block exits" do
      assert catch_exit(
               with_ctx binding: :references do
                 exit(:boom)
               end
             ) == :boom

      assert is_nil(Patterns.Utils.ctx(:binding))
    end
  end

  describe "ctx/1" do
    test "returns values from scoped context" do
      assert is_nil(Patterns.Utils.ctx(:binding))

      result =
        with_ctx binding: :references do
          Patterns.Utils.ctx(:binding)
        end

      assert result == :references
      assert is_nil(Patterns.Utils.ctx(:binding))
    end

    test "returns nil for missing keys" do
      with_ctx binding: :references do
        assert is_nil(Patterns.Utils.ctx(:missing))
      end

      assert is_nil(Patterns.Utils.ctx(:missing))
      assert is_nil(Patterns.Utils.ctx(:binding))
    end
  end
end
