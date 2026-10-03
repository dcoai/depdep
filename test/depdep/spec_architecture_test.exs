defmodule Depdep.SpecArchitectureTest do
  @moduledoc """
  `spec/02-architecture.md` is a map, and a map's failure mode is going stale (#138).

  It cites no code: a relation from a map section to a module cannot be validated,
  because no test verifies "these modules are the run's shape", so it would dangle
  for ever and drown the signal from the relations that can. #120 kept the
  citations for the re-read they forced; this replaces them with a check that
  cannot be rubber-stamped the way a confirmation can.

  Both directions, because each catches a different mistake: a module added and
  never mapped is invisible to a reader, and a module named in the map that no
  longer exists is a lie. Same shape as the switch table held to
  `Depdep.CLI.switches/0`.
  """
  use ExUnit.Case, async: true

  @map "spec/02-architecture.md"

  # Every module the compiled application defines, filtered to those whose source
  # is under `lib/`. Asking the compiled modules rather than globbing source means
  # this cannot drift from what ships; filtering on the source path is what keeps
  # `test/support` out, since `elixirc_paths(:test)` compiles it into the same app.
  # A mix task is a surface of its own, specified in `spec/09-cli.md#profile-task`.
  defp modules do
    :depdep
    |> Application.spec(:modules)
    |> Enum.filter(fn module ->
      case module.__info__(:compile)[:source] do
        nil -> false
        source -> source |> to_string() |> Path.relative_to_cwd() |> String.starts_with?("lib/")
      end
    end)
    |> Enum.map(&inspect/1)
    |> Enum.reject(&String.starts_with?(&1, "Mix.Tasks."))
    |> Enum.sort()
  end

  defp named_in_map do
    ~r/\bDepdep(?:\.[A-Z][A-Za-z0-9_]*)*\b/
    |> Regex.scan(File.read!(@map))
    |> List.flatten()
    |> Enum.uniq()
  end

  # A nested module is covered by an ancestor the map names: the map orients by the
  # module a reader would look for, and `Depdep.Metrics.Phase` is a struct inside
  # `Depdep.Metrics` rather than a part of the architecture of its own. A new
  # TOP-LEVEL module has no ancestor on the map and still fails, which is the case
  # worth catching.
  # Named itself, or its IMMEDIATE parent is named and is not the root namespace.
  #
  # Walking every ancestor would be useless: the map says "Depdep" in prose, so
  # every module would be covered by that and the check would pass for anything.
  # It did, until a probe that deleted a module from the map failed to go red.
  defp mapped?(named, module) do
    parts = String.split(module, ".")

    parent =
      case Enum.drop(parts, -1) do
        [_root] -> nil
        [] -> nil
        ancestors -> Enum.join(ancestors, ".")
      end

    MapSet.member?(named, module) or (parent != nil and MapSet.member?(named, parent))
  end

  test "every module is on the map, itself or through an ancestor" do
    named = MapSet.new(named_in_map())

    for module <- modules() do
      assert mapped?(named, module),
             "#{module} is not named in #{@map}, nor is any ancestor — " <>
               "a module nobody mapped is invisible to a reader"
    end
  end

  test "every module the map names exists" do
    defined = MapSet.new(modules())

    for name <- named_in_map(), name != "Depdep" or MapSet.member?(defined, name) do
      assert MapSet.member?(defined, name),
             "#{@map} names #{name}, which no longer exists — the map has gone stale"
    end
  end

  # The map must not cite code, or the relations it cannot validate come back.
  test "the map cites no code" do
    cited =
      ~r/`((?:Mix\.Tasks\.)?Depdep(?:\.[A-Z][A-Za-z0-9_]*)*(?:\.[a-z_][A-Za-z0-9_]*[?!]?(?:\/\d+)?)?)`/
      |> Regex.scan(File.read!(@map))
      |> Enum.map(&List.last/1)

    assert cited == [],
           "#{@map} backticks #{inspect(cited)}, which surfex reads as a citation. " <>
             "A map relation cannot be validated, so it would dangle for ever."
  end
end
