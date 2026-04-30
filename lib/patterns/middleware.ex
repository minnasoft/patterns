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

  ## Public API

  - Entrypoints: `@middleware` annotations and `run/4`.
  - Callback flow: `process/2` and `yield/2`.
  - `get_private/3`, `put_private/3`, `update_private/4`, and
    `delete_private/2` store middleware metadata on the resolution.
  - `get_super/1`, `put_super/2`, and `update_super/2` inspect or replace the
    operation called after the last middleware yields.

  ## Middleware Modules

  Middleware modules can `use Patterns.Middleware` to import `yield/2` and the
  super helpers, but they should still declare `@behaviour Patterns.Middleware`
  explicitly.

  Middleware modules implement `process/2`. For middleware attached to a function,
  the first argument passed to `process/2` is a list containing the arguments passed
  to the wrapped function. The second argument is a
  `Patterns.Middleware.Resolution` with metadata about the call.

  For annotated functions, `input` is always the wrapped function argument list.
  For direct `run/4` callers, `input` is whatever value was passed to `run/4` or
  the previous `yield/2`.

  `process/2` must return `{result, resolution}`. Calling `yield/2` continues to
  the next middleware, or to the wrapped function when there is no middleware
  left. Returning `{result, resolution}` without calling `yield/2` halts the
  stack.

  ## Return Values

  Calling an annotated function returns only the wrapped result. Middleware
  callbacks, `yield/2`, and `run/4` return `{result, resolution}`. If the wrapped
  function returns `{:ok, post}`, middleware receives and returns
  `{{:ok, post}, resolution}`.

      defmodule Blog.Middlewares.RecordAuditLog do
        use Patterns.Middleware

        @behaviour Patterns.Middleware

        @impl Patterns.Middleware
        def process(args, resolution) do
          yield(args, resolution)
        end
      end

  ## Function Arguments

  Calling `Blog.create_post(%{title: "Hello"})` passes
  `[%{title: "Hello"}]` as `args` to the first middleware. Calling a wrapped
  function with multiple arguments, such as `Blog.publish_post(123, force: true)`,
  passes `[123, [force: true]]`.

  `resolution.args` stores the original argument list. If middleware passes a
  changed value to `yield/2`, the changed value is passed to the rest of the
  stack, but `resolution.args` still refers to the original call.

  ## Private Metadata

  Middleware can use private metadata to communicate with later or earlier
  middleware in the same invocation. Because `yield/2` returns the updated
  resolution, middleware can inspect private metadata written by later middleware.

      def process(args, resolution) do
        {result, resolution} = yield(args, resolution)

        if get_private(resolution, :paginated?) do
          {{:paginated, result}, resolution}
        else
          {result, resolution}
        end
      end

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

  `@middleware` is captured by the next `def` or `defp`. Middleware is tracked
  per function name and arity, not per clause, so an annotated clause wraps the
  whole function/arity. For functions with multiple clauses or default arguments,
  prefer annotating the function head. Different stacks for different clauses of
  the same function are rejected at compile time.

      @middleware Blog.Middlewares.AuthorizeEditor
      def publish_post(post_id, opts \\ [])

      def publish_post(post_id, opts) do
        {:ok, {post_id, opts}}
      end

  ## Yielding

  Middleware continues the stack by calling `yield/2`. Passing a changed
  argument list to `yield/2` calls the wrapped function with those changed
  arguments.

  `yield/2` returns `{result, resolution}` so middleware can inspect the return
  value and any resolution changes made by later middleware.

  For function middleware, pass a list matching the wrapped function arity. If
  the final input cannot be matched to the wrapped arity, the generated wrapper
  raises.

  Middleware runs in the order it is declared. In a stack like
  `[AuthorizeEditor, RecordAuditLog]`, `AuthorizeEditor` runs first and
  `RecordAuditLog` runs inside it. When the innermost, rightmost middleware calls
  `yield/2`, `Patterns.Middleware` calls the original wrapped function.

  Code before `yield/2` runs before the rest of the stack and the wrapped
  function. Code after `yield/2` runs after the wrapped function returns.

      def process([attrs], resolution) do
        attrs = Map.update!(attrs, :title, &String.trim/1)

        case yield([attrs], resolution) do
          {{:ok, post}, resolution} ->
            {{:ok, Map.put(post, :audited, true)}, resolution}

          {error, resolution} ->
            {error, resolution}
        end
      end

  ## Super

  The super function is the operation called when the last middleware yields. For
  functions wrapped with `@middleware`, super calls the original function body.
  Code that uses `run/4` directly can provide a different super function.

      {result, resolution} =
        Patterns.Middleware.run(stack, args, resolution, fn args, resolution ->
          call_existing_operation(args, resolution)
        end)

  Middleware can replace super before continuing the stack:

      def process(args, resolution) do
        resolution =
          put_super(resolution, fn args, resolution ->
            call_remote_operation(args, resolution)
          end)

        yield(args, resolution)
      end

  Middleware can also wrap super before continuing the stack. `super` returns
  the wrapped operation's raw result, not `{result, resolution}`. In this example,
  `{:ok, result}` is the wrapped operation result.

      def process(args, resolution) do
        resolution =
          update_super(resolution, fn super ->
            fn args, resolution ->
              {:ok, result} = super.(args, resolution)
              {:ok, Map.put(result, :audited, true)}
            end
          end)

        {result, resolution} = yield(args, resolution)

        {result, resolution}
      end

  If multiple middleware wrap super before yielding, later middleware in the
  stack wrap the super function produced by earlier middleware.

  Super changes affect only the current invocation because super is stored on the
  resolution.

  ## Caveats

  > #### Clause matching happens later {: .warning}
  >
  > Middleware currently runs before the original function clauses and guards match.
  > Do not rely on middleware receiving only values accepted by the wrapped clauses.
  > This ordering is an implementation detail and may change in the future.

  > #### Middleware return values {: .warning}
  >
  > Middleware return values are not normalized or validated. Middleware must return
  > `{result, resolution}`.

  ## Halting

  Middleware can also halt the stack by returning `{result, resolution}` without
  calling `yield/2`.

      def process([user | _] = args, resolution) do
        if user.admin? do
          yield(args, resolution)
        else
          {{:error, :unauthorized}, resolution}
        end
      end
  """

  alias Patterns.Middleware.Resolution

  @doc """
  Handles the current middleware value.

  When middleware is attached to a function with `@middleware`, the first
  argument passed to `process/2` is the list of arguments passed to the wrapped
  function.

  For example, a wrapped `create_post(attrs)` function receives `[attrs]`, while
  a wrapped `publish_post(post_id, opts)` function receives `[post_id, opts]`.

  Call `Patterns.Middleware.yield/2` with the current value and resolution to
  continue the stack. Returning `{result, resolution}` without yielding halts the
  stack and uses `result` as the wrapped function result.

  Work done before `yield/2` pre-processes the call. Work done after `yield/2`
  post-processes the result returned by the rest of the stack.
  """
  @callback process(term(), Resolution.t()) :: {term(), Resolution.t()}

  @doc """
  Sets up `@middleware` annotations for the using module.

  Also imports `yield/2`, private helpers, and super helpers for middleware
  implementations.
  """
  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__),
        only: [
          delete_private: 2,
          get_private: 2,
          get_private: 3,
          get_super: 1,
          put_private: 3,
          put_super: 2,
          update_private: 4,
          update_super: 2,
          yield: 2
        ]

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
      |> normalize_stack!()

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
      |> ensure_single_function_head_annotated!(env)

    overridables = Enum.map(definitions, fn {_kind, name, arity, _stack} -> {name, arity} end)

    wrappers =
      Enum.map(definitions, fn {kind, name, arity, stack} ->
        args = Macro.generate_arguments(arity, __MODULE__)
        super_args = Macro.generate_arguments(arity, __MODULE__)
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

            {result, _resolution} =
              Patterns.Middleware.run(resolution.middleware, args, resolution, fn input, _resolution ->
                [unquote_splicing(super_args)] = input
                super(unquote_splicing(super_args))
              end)

            result
          end
        end
      end)

    quote do
      defoverridable unquote(overridables)
      unquote_splicing(wrappers)
    end
  end

  @doc """
  Runs a middleware stack, then calls `super` after the last middleware yields.

  Returns `{result, resolution}`.

  `run/4` is exposed for code that wants to integrate with the middleware
  pattern without using `@middleware` annotations. Use it when the stack, input,
  or super operation needs to be selected dynamically, or when a higher-level
  wrapper needs more parameterized behavior than function annotations can
  express.

  The `super` function receives the current input and resolution, then returns
  the wrapped operation's raw result. `run/4` wraps that raw result with the final
  resolution.

  For functions wrapped with `@middleware`, `super` calls the original function.
  Code that uses `Patterns.Middleware` directly can pass a different `super`
  function.

  For example, another library or wrapper module could run middleware around an
  existing operation:

      resolution = %Patterns.Middleware.Resolution{
        module: Blog,
        function: :create_post,
        arity: 1,
        args: [attrs]
      }

      {result, resolution} =
        Patterns.Middleware.run(stack, args, resolution, fn args, resolution ->
          call_existing_operation(args, resolution)
        end)

  The `super` function must be an arity-2 function. If it returns
  `{result, resolution}`, that tuple is treated as the raw result.
  """
  @spec run([module()] | module(), term(), Resolution.t(), (term(), Resolution.t() -> term())) ::
          {term(), Resolution.t()}
  def run(stack, input, %Resolution{} = resolution, super) when is_function(super, 2) do
    stack = normalize_stack!(stack)

    resolution
    |> Map.put(:middleware, stack)
    |> put_super(super)
    |> then(&yield(input, &1))
  end

  @doc """
  Returns a value from `resolution.private`.

  Returns `default` when the key is missing.

  ## Example

      get_private(resolution, :paginated?, false)
  """
  @spec get_private(Resolution.t(), term(), term()) :: term()
  def get_private(%Resolution{} = resolution, key, default \\ nil) do
    Map.get(resolution.private, key, default)
  end

  @doc """
  Stores a value in `resolution.private`.

  ## Example

      resolution = put_private(resolution, :paginated?, true)
  """
  @spec put_private(Resolution.t(), term(), term()) :: Resolution.t()
  def put_private(%Resolution{} = resolution, key, value) do
    private = Map.put(resolution.private, key, value)

    %{resolution | private: private}
  end

  @doc """
  Updates a value in `resolution.private`.

  ## Example

      resolution = update_private(resolution, :attempts, 0, &(&1 + 1))
  """
  @spec update_private(Resolution.t(), term(), term(), (term() -> term())) :: Resolution.t()
  def update_private(%Resolution{} = resolution, key, default, fun) when is_function(fun, 1) do
    private = Map.update(resolution.private, key, default, fun)

    %{resolution | private: private}
  end

  @doc """
  Deletes a value from `resolution.private`.

  ## Example

      resolution = delete_private(resolution, :paginated?)
  """
  @spec delete_private(Resolution.t(), term()) :: Resolution.t()
  def delete_private(%Resolution{} = resolution, key) do
    private = Map.delete(resolution.private, key)

    %{resolution | private: private}
  end

  @doc """
  Returns the super function for a middleware invocation.

  Raises when no super function is available.
  """
  @spec get_super(Resolution.t()) :: (term(), Resolution.t() -> term())
  def get_super(%Resolution{} = resolution) do
    resolution.super || raise KeyError, key: :super, term: resolution
  end

  @doc """
  Replaces the super function for a middleware invocation.

  Use this when middleware should replace the operation that runs after the last
  middleware yields.
  """
  @spec put_super(Resolution.t(), (term(), Resolution.t() -> term())) :: Resolution.t()
  def put_super(%Resolution{} = resolution, super) when is_function(super, 2) do
    %{resolution | super: super}
  end

  @doc """
  Updates the super function for a middleware invocation.

  `fun` receives the current super function and must return a replacement super
  function. Raises when no super function is available.

  ## Example

      resolution =
        update_super(resolution, fn super ->
          fn args, resolution ->
            case super.(args, resolution) do
              {:ok, result} -> {:ok, Map.put(result, :processed?, true)}
              error -> error
            end
          end
        end)
  """
  @spec update_super(
          Resolution.t(),
          ((term(), Resolution.t() -> term()) -> (term(), Resolution.t() -> term()))
        ) :: Resolution.t()
  def update_super(%Resolution{} = resolution, fun) when is_function(fun, 1) do
    super = resolution |> get_super() |> fun.()

    put_super(resolution, super)
  end

  @doc """
  Continues the active middleware stack with the given value.

  Returns `{result, resolution}`. If there is more middleware, `yield/2` calls
  the next middleware's `process/2`. If the stack is empty, it calls the current
  super function and wraps its raw result with the current resolution.

  ## Example

      {result, resolution} = yield(args, resolution)
  """
  @spec yield(term(), Resolution.t()) :: {term(), Resolution.t()}
  def yield(input, %Resolution{middleware: [middleware | rest]} = resolution) do
    middleware.process(input, %{resolution | middleware: rest})
  end

  def yield(input, %Resolution{middleware: []} = resolution) do
    result =
      resolution
      |> get_super()
      |> then(& &1.(input, resolution))

    {result, resolution}
  end

  # NOTE: Public but hidden so integration code using run/4 directly can
  # normalize stacks the same way annotations do.
  @doc false
  @spec normalize_stack!([module()] | module()) :: [module()]
  def normalize_stack!(middleware) when is_atom(middleware) do
    [middleware]
  end

  def normalize_stack!(middleware) when is_list(middleware) do
    Enum.flat_map(middleware, &normalize_stack!/1)
  end

  defp ensure_single_function_head_annotated!(definitions, env) do
    definitions
    |> Enum.group_by(fn {_kind, name, arity, _stack} -> {name, arity} end)
    |> Enum.map(fn {{name, arity}, definitions} ->
      stacks = definitions |> Enum.map(fn {_kind, _name, _arity, stack} -> stack end) |> Enum.uniq()

      if length(stacks) > 1 do
        raise CompileError,
          file: env.file,
          description: "conflicting @middleware stacks for #{name}/#{arity}; annotate the function head once"
      end

      hd(definitions)
    end)
  end
end
