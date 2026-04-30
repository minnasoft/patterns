defmodule Patterns.Utils do
  @moduledoc "Utilities for building pattern modules."

  @ctx_key {__MODULE__, :ctx}

  @doc """
  Runs `block` with scoped process-local context.

  `ctx` may be a map or keyword list. It is converted to a map and merged into
  the current context for the duration of the block. Nested calls override
  duplicate keys while preserving sibling keys.

  > #### Process-local context {: .info}
  >
  > Context is stored in the process dictionary. It is visible only to the current
  > process and does not cross `Task`, spawned process, Dataloader, or other async
  > boundaries.

  The previous context is restored after the block exits, including when the
  block raises, throws, or exits.

  ## Example

      ctx(:binding)
      #=> nil

      with_ctx binding: :references do
        ctx(:binding)
        #=> :references
      end

      ctx(:binding)
      #=> nil
  """
  defmacro with_ctx(ctx, do: block) do
    quote do
      previous_ctx = Process.get(unquote(@ctx_key))
      Process.put(unquote(@ctx_key), Map.merge(previous_ctx || %{}, Map.new(unquote(ctx))))

      try do
        unquote(block)
      after
        if previous_ctx do
          Process.put(unquote(@ctx_key), previous_ctx)
        else
          Process.delete(unquote(@ctx_key))
        end
      end
    end
  end

  @doc """
  Returns a value from the current scoped context.

  See `with_ctx/2` for more information.

  ## Example

      ctx(:binding)
      #=> nil

      with_ctx binding: :references do
        ctx(:binding)
        #=> :references
      end

      ctx(:binding)
      #=> nil
  """
  @spec ctx(term()) :: term()
  def ctx(key) do
    @ctx_key
    |> Process.get(%{})
    |> Map.get(key)
  end

  @doc """
  Defines delegates for every public function exported by `module`.

  ## Example

      defmodule MyDelegates do
        import Patterns.Utils

        defdelegate_all String
      end

      MyDelegates.upcase("hello")

  Private functions are ignored because only public functions are returned by
  `module.__info__(:functions)`.
  """
  defmacro defdelegate_all(module) do
    module = Macro.expand(module, __CALLER__)

    for {name, arity} <- module.__info__(:functions) do
      args = Macro.generate_arguments(arity, __MODULE__)

      quote do
        defdelegate unquote(name)(unquote_splicing(args)), to: unquote(module)
      end
    end
  end
end
