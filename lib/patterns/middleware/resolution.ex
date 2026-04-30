defmodule Patterns.Middleware.Resolution do
  @moduledoc """
  Runtime metadata for a `Patterns.Middleware` invocation.
  """

  @type t :: %__MODULE__{
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          args: [term()],
          middleware: [module()],
          private: map()
        }

  defstruct module: nil,
            function: nil,
            arity: 0,
            args: [],
            middleware: [],
            private: %{}
end
