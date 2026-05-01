defmodule Patterns.Proxy.DSL do
  @moduledoc false

  defmacro with_proxy(supervisor, scope, do: clauses) do
    build_with_proxy(supervisor, scope, [], clauses)
  end

  defmacro with_proxy(supervisor, scope, opts, do: clauses) do
    build_with_proxy(supervisor, scope, opts, clauses)
  end

  defp build_with_proxy(supervisor, scope, opts, clauses) do
    fun = {:fn, [], normalize_clauses!(clauses)}

    quote do
      Patterns.Proxy.with_proxy(unquote(supervisor), unquote(scope), unquote(opts), unquote(fun))
    end
  end

  defp normalize_clauses!({:->, _meta, _args} = clause) do
    normalize_clauses!([clause])
  end

  defp normalize_clauses!(clauses) when is_list(clauses) do
    if Enum.all?(clauses, &proxy_clause?/1) do
      clauses
    else
      raise ArgumentError, "with_proxy block must be written as: proxy -> ..."
    end
  end

  defp normalize_clauses!(_clauses) do
    raise ArgumentError, "with_proxy block must be written as: proxy -> ..."
  end

  defp proxy_clause?({:->, _meta, [args, _body]}) when is_list(args) do
    length(args) == 1
  end

  defp proxy_clause?(_clause) do
    false
  end
end
