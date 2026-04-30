defmodule Patterns.Middleware do
  @moduledoc """
  Function middleware for explicitly annotated definitions.

  ## Basic Usage

  `Patterns.Middleware` wraps functions that opt in with `@middleware`:

      defmodule Blog do
        use Patterns.Middleware

        @middleware [Blog.Middlewares.AuthorizeEditor, Blog.Middlewares.RecordAuditLog]
        def create_post(attrs) do
          {:ok, attrs}
        end
      end

  ## Middleware Modules

  Middleware modules implement `call/2`. For middleware attached to a function,
  the first argument passed to `call/2` is a list containing the arguments passed
  to the wrapped function. The second argument is a
  `Patterns.Middleware.Resolution` with metadata about the call.

      defmodule Blog.Middlewares.RecordAuditLog do
        @behaviour Patterns.Middleware

        @impl Patterns.Middleware
        def call(args, resolution) do
          Patterns.Middleware.yield(args, resolution)
        end
      end

  ## Function Arguments

  Calling `Blog.create_post(%{title: "Hello"})` passes
  `[%{title: "Hello"}]` as `args` to the first middleware. Calling a wrapped
  function with multiple arguments, such as `Blog.publish_post(123, force: true)`,
  passes `[123, [force: true]]`.

  ## Stacking Middleware

  Middleware can be attached to public or private functions. A stack can be
  declared as a list, or by repeating `@middleware` before the function:

      @middleware Blog.Middlewares.AuthorizeEditor
      @middleware Blog.Middlewares.RecordAuditLog
      def publish_post(post_id) do
        {:ok, {:published, post_id}}
      end

      @middleware [Blog.Middlewares.AuthorizeEditor, Blog.Middlewares.RecordAuditLog]
      defp persist_post(attrs) do
        {:ok, attrs}
      end

  ## Yielding

  Middleware continues the stack by calling `yield/2`. Passing a changed
  argument list to `yield/2` calls the wrapped function with those changed
  arguments.

  Middleware runs in the order it is declared. In a stack like
  `[AuthorizeEditor, RecordAuditLog]`, `AuthorizeEditor` runs first and
  `RecordAuditLog` runs inside it. When the innermost, rightmost middleware calls
  `yield/2`, `Patterns.Middleware` calls the original wrapped function.

  Code before `yield/2` runs before the rest of the stack and the wrapped
  function. Code after `yield/2` runs after the wrapped function returns.

      def call([attrs], resolution) do
        attrs = Map.update!(attrs, :title, &String.trim/1)

        case Patterns.Middleware.yield([attrs], resolution) do
          {:ok, post} -> {:ok, Map.put(post, :audited, true)}
          error -> error
        end
      end

  ## Halting

  Middleware can also halt the stack by returning without calling `yield/2`.
  """

  alias Patterns.Middleware.Resolution

  @doc """
  Handles the current middleware value.

  When middleware is attached to a function with `@middleware`, the first
  argument passed to `call/2` is the list of arguments passed to the wrapped
  function.

  For example, a wrapped `create_post(attrs)` function receives `[attrs]`, while
  a wrapped `publish_post(post_id, opts)` function receives `[post_id, opts]`.

  Call `Patterns.Middleware.yield/2` with the current value and resolution to
  continue the stack. Returning without yielding halts the stack and uses that
  value as the wrapped function result.

  Work done before `yield/2` pre-processes the call. Work done after `yield/2`
  post-processes the result returned by the rest of the stack.
  """
  @callback call(term(), Resolution.t()) :: term()

  @doc """
  Sets up `@middleware` annotations for the using module.
  """
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :middleware, accumulate: true)
      Module.register_attribute(__MODULE__, :__patterns_middleware_defs__, accumulate: true)

      @before_compile unquote(__MODULE__)
      @on_definition {unquote(__MODULE__), :__on_definition__}
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) when kind in [:def, :defp] do
    stack =
      env.module
      |> Module.get_attribute(:middleware)
      |> Enum.reverse()
      |> Enum.flat_map(fn
        middleware when is_list(middleware) -> middleware
        middleware -> [middleware]
      end)

    Module.delete_attribute(env.module, :middleware)

    if stack != [] do
      Module.put_attribute(env.module, :__patterns_middleware_defs__, {kind, name, length(args), stack})
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body) do
    :ok
  end

  @doc false
  defmacro __before_compile__(env) do
    definitions =
      env.module
      |> Module.get_attribute(:__patterns_middleware_defs__)
      |> Enum.reverse()
      |> Enum.uniq_by(fn {_kind, name, arity, _stack} -> {name, arity} end)

    overridables = Enum.map(definitions, fn {_kind, name, arity, _stack} -> {name, arity} end)

    wrappers =
      Enum.map(definitions, fn {kind, name, arity, stack} ->
        args = Macro.generate_arguments(arity, __MODULE__)
        terminal_args = Macro.generate_arguments(arity, __MODULE__)
        escaped_stack = Macro.escape(normalize_stack!(stack))

        quote do
          unquote(kind)(unquote(name)(unquote_splicing(args))) do
            args = [unquote_splicing(args)]

            resolution = %Resolution{
              module: __MODULE__,
              function: unquote(name),
              arity: unquote(arity),
              args: args,
              middleware: unquote(escaped_stack),
              private: %{}
            }

            Patterns.Middleware.run(resolution.middleware, args, resolution, fn input, _resolution ->
              [unquote_splicing(terminal_args)] = input
              super(unquote_splicing(terminal_args))
            end)
          end
        end
      end)

    quote do
      defoverridable unquote(overridables)
      unquote_splicing(wrappers)
    end
  end

  @doc """
  Runs a middleware stack, then calls `final` after the last middleware yields.

  For functions wrapped with `@middleware`, `final` calls the original function.
  Code that uses `Patterns.Middleware` directly can pass a different `final`
  function.

  For example, another library or wrapper module could run middleware around an
  existing operation:

      Patterns.Middleware.run(stack, args, resolution, fn args, resolution ->
        call_existing_operation(args, resolution)
      end)
  """
  @spec run([module()] | module(), term(), Resolution.t(), (term(), Resolution.t() -> term())) :: term()
  def run(stack, input, %Resolution{} = resolution, final) when is_function(final, 2) do
    stack = normalize_stack!(stack)
    private = Map.put(resolution.private || %{}, :__patterns_middleware_final__, final)

    yield(input, %{resolution | middleware: stack, private: private})
  end

  @doc """
  Continues the active middleware stack with the given value.
  """
  @spec yield(term(), Resolution.t()) :: term()
  def yield(input, %Resolution{middleware: [middleware | rest]} = resolution) do
    middleware.call(input, %{resolution | middleware: rest})
  end

  def yield(input, %Resolution{middleware: []} = resolution) do
    resolution.private
    |> Map.fetch!(:__patterns_middleware_final__)
    |> then(& &1.(input, resolution))
  end

  @doc false
  @spec normalize_stack!([module()] | module()) :: [module()]
  def normalize_stack!(middleware) when is_atom(middleware) do
    [middleware]
  end

  def normalize_stack!(middleware) when is_list(middleware) do
    Enum.flat_map(middleware, &normalize_stack!/1)
  end
end
