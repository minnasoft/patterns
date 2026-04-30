defmodule Patterns.Middleware.Resolution do
  @moduledoc """
  Runtime metadata for a `Patterns.Middleware` invocation.

  `args` stores the original argument list passed to the wrapped function or to
  `run/4`. Middleware can pass a different value to `yield/2`; doing so changes
  the value passed to the rest of the stack, but it does not change `args`.

  Annotated functions build resolutions automatically. Direct `run/4` callers
  create one explicitly with `module`, `function`, `arity`, and `args`.

  ## Fields

  - `module` is the module that owns the wrapped function or direct middleware
    invocation.
  - `function` is the wrapped function name, or the operation name supplied by a
    direct `run/4` caller.
  - `arity` is the wrapped function arity, or the operation arity supplied by a
    direct `run/4` caller.
  - `args` is the original argument list.
  - `middleware` is the remaining middleware stack for the current yield. Treat
    this as runtime state; middleware should normally call `yield/2` instead of
    updating it directly.
  - `super` is the arity-2 function called after the last middleware yields.
    `run/4` installs this automatically.
  - `private` stores middleware metadata. Use `Patterns.Middleware` private
    helpers instead of updating it directly.
  """

  @type t :: %__MODULE__{
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          args: [term()],
          middleware: [module()],
          super: (term(), __MODULE__.t() -> term()) | nil,
          private: map()
        }

  defstruct module: nil,
            function: nil,
            arity: 0,
            args: [],
            middleware: [],
            super: nil,
            private: %{}
end
