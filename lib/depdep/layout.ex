defmodule Depdep.Layout do
  @moduledoc """
  Which Mix projects depdep should operate on.

  Three cases, resolved in this order, so the common one needs no configuration
  at all:

    1. **Explicitly named.** `--project DIR`, repeatable. Always wins.
    2. **A single Mix project.** The root itself has a `mix.exs`. This is what
       almost every repository is, and it needs nothing passed.
    3. **A poncho.** No `mix.exs` at the root, so every `mix.exs` beneath it is a
       member — each with its own `deps/` and `_build/`, which is precisely the
       arrangement that makes a package get compiled once per member and is why
       depdep exists.

  `deps/` and `_build/` are excluded from discovery, since a dependency's own
  `mix.exs` is not a member. `--exclude SCOPE` drops a whole top-level directory,
  which is how a member on a different toolchain is kept out: its objects would
  key differently on `elixir=` and `otp=` and could never collide with a
  sibling's, so scanning it is work for nothing.
  """

  @never ["/deps/", "/_build/"]

  @doc "Root and options -> a sorted list of project directories, relative to the root."
  def projects(root, opts \\ []) do
    case Keyword.get_values(opts, :project) do
      [] -> discover(root, Keyword.get_values(opts, :exclude))
      given -> Enum.sort(given)
    end
  end

  defp discover(root, excluded) do
    if File.exists?(Path.join(root, "mix.exs")) do
      ["."]
    else
      Path.join(root, "**/mix.exs")
      |> Path.wildcard()
      |> Enum.reject(fn p -> Enum.any?(@never, &String.contains?(p, &1)) end)
      |> Enum.map(&(&1 |> Path.dirname() |> Path.relative_to(root)))
      |> Enum.reject(&(&1 == "."))
      |> Enum.reject(fn m -> hd(Path.split(m)) in excluded end)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end
end
