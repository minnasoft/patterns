defmodule Patterns.UtilsTest do
  use ExUnit.Case, async: true

  import Patterns.Utils, only: [update_ctx: 2, with_ctx: 2]

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

      {result, ctx} =
        with_ctx binding: :references do
          assert Patterns.Utils.ctx(:binding) == :references

          {inner_result, inner_ctx} =
            with_ctx binding: :target do
              Patterns.Utils.ctx(:binding)
            end

          assert inner_result == :target
          assert inner_ctx.binding == :target
          assert Patterns.Utils.ctx(:binding) == :references

          inner_result
        end

      assert result == :target
      assert ctx.binding == :references
      assert is_nil(Patterns.Utils.ctx(:binding))
    end

    test "merges nested context without removing sibling keys" do
      assert is_nil(Patterns.Utils.ctx(:binding))
      assert is_nil(Patterns.Utils.ctx(:schema))

      {_result, ctx} =
        with_ctx binding: :references, schema: Source do
          assert Patterns.Utils.ctx(:binding) == :references
          assert Patterns.Utils.ctx(:schema) == Source

          {_result, inner_ctx} =
            with_ctx binding: :target do
              assert Patterns.Utils.ctx(:binding) == :target
              assert Patterns.Utils.ctx(:schema) == Source
            end

          assert inner_ctx.binding == :target
          assert inner_ctx.schema == Source
          assert Patterns.Utils.ctx(:binding) == :references
          assert Patterns.Utils.ctx(:schema) == Source
        end

      assert ctx.binding == :references
      assert ctx.schema == Source
      assert is_nil(Patterns.Utils.ctx(:binding))
      assert is_nil(Patterns.Utils.ctx(:schema))
    end

    test "accepts map context" do
      {_result, ctx} =
        with_ctx %{binding: :references} do
          assert Patterns.Utils.ctx(:binding) == :references
        end

      assert ctx.binding == :references
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

  describe "update_ctx/2" do
    test "updates the scoped context and returns the updated value" do
      {result, ctx} =
        with_ctx memo: %{invalidated?: false} do
          update_ctx(:memo, &%{&1 | invalidated?: true})
        end

      assert result == %{invalidated?: true}
      assert ctx.memo.invalidated?
      assert is_nil(Patterns.Utils.ctx(:memo))
    end

    test "nested scopes keep inherited context updates" do
      {_result, ctx} =
        with_ctx memo: %{invalidated?: false} do
          {_result, _ctx} =
            with_ctx binding: :comments do
              update_ctx(:memo, &%{&1 | invalidated?: true})
            end
        end

      assert ctx.memo.invalidated?
    end

    test "nested scopes do not leak overridden context updates" do
      {_result, ctx} =
        with_ctx binding: :posts do
          {_result, _ctx} =
            with_ctx binding: :comments do
              update_ctx(:binding, fn _binding -> :updated_comments end)
            end
        end

      assert ctx.binding == :posts
    end
  end

  describe "ctx/1" do
    test "returns values from scoped context" do
      assert is_nil(Patterns.Utils.ctx(:binding))

      {result, _ctx} =
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
