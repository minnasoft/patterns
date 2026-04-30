defmodule Patterns.Utils do
  @moduledoc "Utilities for building pattern modules."

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
