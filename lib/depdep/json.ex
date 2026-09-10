defmodule Depdep.Json do
  @moduledoc """
  The smallest JSON writer that does the job: maps, lists, strings, numbers,
  booleans and nil.

  Written out rather than taken from a library for the same reason `Depdep.S3`
  is: depdep runs before `mix deps.get`, so `deps/0` is empty and has to stay
  that way.

  **Writing only.** Depdep produces JSON — its own measurements — and consumes
  none: what a store returns is XML, which `:xmerl` already reads. A decoder
  would be code with no caller.

  `Elixir.JSON` would do and arrived in 1.18; `mix.exs` supports `~> 1.15`, so
  this cannot rely on it being there.
  """

  @doc "Encodes a term as JSON. Map keys are sorted, so output is a function of input."
  def encode(term), do: term |> encoded() |> IO.iodata_to_binary()

  # Order matters: nil/true/false are atoms, and a struct is a map.
  defp encoded(nil), do: "null"
  defp encoded(true), do: "true"
  defp encoded(false), do: "false"
  defp encoded(n) when is_integer(n), do: Integer.to_string(n)

  # A float that is not finite has no JSON representation, and silently writing
  # something else would corrupt a measurement rather than fail one.
  defp encoded(n) when is_float(n), do: Float.to_string(n)
  defp encoded(s) when is_binary(s), do: string(s)
  defp encoded(a) when is_atom(a), do: a |> Atom.to_string() |> string()

  defp encoded(list) when is_list(list),
    do: ["[", list |> Enum.map(&encoded/1) |> Enum.intersperse(","), "]"]

  defp encoded(%_{} = struct), do: struct |> Map.from_struct() |> encoded()

  defp encoded(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> [k |> to_string() |> string(), ":", encoded(v)] end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp string(s), do: [?", escape(s, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  # Every other control character has to be escaped for the output to be valid
  # JSON at all; a raw one in a unit label would produce a document nothing can
  # parse, which is worse than an ugly one.
  defp escape(<<c::utf8, rest::binary>>, acc) when c < 0x20,
    do: escape(rest, [:io_lib.format("\\u~4.16.0b", [c]) | acc])

  defp escape(<<c::utf8, rest::binary>>, acc), do: escape(rest, [<<c::utf8>> | acc])
end
