defmodule Depdep.Layout do
  @moduledoc """
  Which Mix projects depdep should operate on.

  Resolved in this order, so the common cases need no configuration at all:

    1. **Explicitly named.** `--project DIR`, repeatable. Always wins.
    2. **A poncho.** Every `mix.exs` beneath the root is a member — each with its
       own `deps/` and `_build/`, which is precisely the arrangement that makes a
       package get compiled once per member and is why depdep exists. **The root
       having a `mix.exs` of its own does not preclude this**: a poncho with a
       root coordinator project is an ordinary shape, and the root joins its
       members rather than replacing them.
    3. **A single Mix project.** The root has a `mix.exs` and there is nothing
       beneath it. This is what almost every repository is.

  Two things are never members:

    * Anything under `deps/` or `_build/` — a dependency's own `mix.exs` is not a
      member.
    * **A directory with a `mix.exs` but no `mix.lock`.** Without a lock there is
      nothing to key, so such a directory has no objects either way. This is what
      keeps a fixture or vendored project from becoming a phantom member of the
      repository containing it, and in a real poncho it is what separates
      buildable members from path dependencies that are only ever compiled by a
      parent. Measured on `dco-tek/agentronic`: 52 `mix.exs`, 38 `mix.lock`.

      The count of directories dropped this way is reported once per run, never
      once per directory — fourteen identical lines is noise, and noise that
      repeats is noise that gets filtered.

      The rule applies to discovered members, **not** to case 3. A root you have
      pointed depdep at is not a guess, so a single project without a lock is
      still that project.

  `--exclude PREFIX` drops a member and everything beneath it, matched on
  **segment boundaries** — `--exclude tools` drops `tools/cli` and leaves
  `tools_vendor/x` alone. It exists to keep out a member on a different
  toolchain, whose objects key differently on `elixir=` and `otp=` and could
  never collide with a sibling's, so scanning it is work for nothing. Because a
  toolchain varies per member rather than per top-level group, a prefix is the
  right granularity: `--exclude logic-analyzer/eval` is as valid as
  `--exclude logic-analyzer`.
  """

  @never ["/deps/", "/_build/"]

  @doc """
  Root and options -> `{sorted project directories, notes}`, relative to the root.

  Notes are returned rather than printed so IO stays in `Depdep.CLI`, and are
  about the layout itself — what discovery declined to treat as a member, and
  why.
  """
  def projects(root, opts \\ []) do
    case Keyword.get_values(opts, :project) do
      [] -> discover(root, Keyword.get_values(opts, :exclude))
      given -> {Enum.sort(given), []}
    end
  end

  defp discover(root, excluded) do
    members =
      Path.join(root, "**/mix.exs")
      |> Path.wildcard()
      |> Enum.reject(fn p -> Enum.any?(@never, &String.contains?(p, &1)) end)
      |> Enum.map(&(&1 |> Path.dirname() |> Path.relative_to(root)))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "."))
      |> Enum.reject(&excluded?(&1, excluded))

    {locked, unlocked} =
      Enum.split_with(members, &File.regular?(Path.join([root, &1, "mix.lock"])))

    {select(root, locked), notes(unlocked)}
  end

  # With no members, a root `mix.exs` is a single project — case 3, and the case
  # nearly every consumer is. With members, the root joins them if it is itself a
  # project.
  defp select(root, []), do: if(root_project?(root), do: ["."], else: [])

  defp select(root, locked),
    do: Enum.sort(if(root_project?(root), do: ["." | locked], else: locked))

  defp root_project?(root), do: File.regular?(Path.join(root, "mix.exs"))

  # Segment-wise, so `tools` cannot match `tools_vendor`.
  defp excluded?(member, excluded) do
    segments = Path.split(member)
    Enum.any?(excluded, &List.starts_with?(segments, Path.split(&1)))
  end

  defp notes([]), do: []

  defp notes(unlocked) do
    [
      "#{length(unlocked)} #{plural(unlocked)} a mix.exs but no mix.lock — not members, nothing to key"
    ]
  end

  defp plural([_]), do: "directory has"
  defp plural(_), do: "directories have"
end
