defmodule Patterns.Guards do
  @moduledoc "Guard helpers for pattern modules."

  @doc """
  Returns true when `value` is keyword-shaped.

  This guard intentionally checks only what Elixir guard expressions can check:
  the value is a list and either empty or starts with a two-tuple whose key is an
  atom.

  Guards cannot call arbitrary functions or recursively inspect every element in
  a list. See the Elixir documentation for the list of expressions allowed in
  guards: https://hexdocs.pm/elixir/patterns-and-guards.html#guards

  For example, `[{:name, "Rin"}, :bad]` is keyword-shaped for this guard because
  the first element is a valid atom-key tuple, but it is not a valid keyword list.

  Use `Keyword.keyword?/1` outside guards when every element must be validated.
  """
  defguard is_keyword(value)
           when is_list(value) and
                  (value == [] or
                     (is_tuple(hd(value)) and tuple_size(hd(value)) == 2 and is_atom(elem(hd(value), 0))))
end
