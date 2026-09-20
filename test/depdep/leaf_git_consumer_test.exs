defmodule Depdep.LeafGitConsumerTest do
  @moduledoc """
  extc's shape, end to end through the real modules (#81, from extc #170).

  Two git dependencies: `extla`, which has hex children of its own, and
  `surfex`, a leaf with none. An `only: [:dev, :docs]` root brings in `ex_doc`
  and its chain, which nothing under `test` reaches. On v0.4.0 `surfex` was
  absent from the parsed graph — only parents were keys — so it read as
  `:unknown`, was skipped on every pass, kept the env walk incomplete, and
  left the six doc dependencies `:ambiguous`: requested, missed, and handed to
  `mix deps.compile`, which refused them for `test`. #70 names every node the
  dot touches; this test pins the consumer case so it cannot come back.
  """
  use ExUnit.Case, async: true

  import Depdep.LockFixture

  alias Depdep.{EnvSet, Graph, Key, Lock}

  # What `mix deps.tree --format dot` printed in extc: surfex only ever a child.
  @dot ~S"""
  digraph "dependency tree" {
    "extc" -> "extla"
    "extla" -> "jason"
    "extla" -> "telemetry"
    "extc" -> "surfex"
    "extc" -> "jason"
    "extc" -> "ex_doc"
    "ex_doc" -> "earmark_parser"
    "ex_doc" -> "makeup_elixir"
    "ex_doc" -> "makeup_erlang"
    "makeup_elixir" -> "makeup"
    "makeup_elixir" -> "nimble_parsec"
    "makeup_erlang" -> "makeup"
    "makeup" -> "nimble_parsec"
  }
  """

  @docs ~w(ex_doc earmark_parser makeup makeup_elixir makeup_erlang nimble_parsec)

  defp lock do
    Map.new([
      git("extla"),
      git("surfex"),
      hex("jason", "1.4.4", []),
      hex("telemetry", "1.3.0", []),
      hex("ex_doc", "0.38.2", ["earmark_parser", "makeup_elixir", "makeup_erlang"]),
      hex("earmark_parser", "1.4.44", []),
      hex("makeup_elixir", "1.0.1", ["makeup", "nimble_parsec"]),
      hex("makeup_erlang", "1.0.2", ["makeup"]),
      hex("makeup", "1.2.1", ["nimble_parsec"]),
      hex("nimble_parsec", "1.4.2", [])
    ])
  end

  # extc's mix.exs under MIX_ENV=test: ex_doc is declared but not admitted.
  @roots_under_test ~w(extla surfex jason)

  test "the leaf is present in the graph with an empty closure, like the parent with a full one" do
    graph = Graph.parse(@dot)
    assert graph["surfex"] == []
    assert graph["extla"] == ["jason", "telemetry"]
  end

  test "Lock.children answers [] for the leaf, not :unknown" do
    graph = Graph.parse(@dot)
    assert Lock.children(lock()["surfex"], graph, "surfex") == []

    assert Lock.children(lock()["extla"], graph, "extla") == [
             {"jason", false},
             {"telemetry", false}
           ]
  end

  test "both git dependencies key once the graph is in; only the graph-less first pass skips" do
    {:ok, keys} = Key.compute(lock(), %{}, toolchain(), Graph.parse(@dot))
    assert {:key, _} = keys["surfex"]
    assert {:key, _} = keys["extla"]

    {:ok, first_pass} = Key.compute(lock(), %{}, toolchain(), %{})
    assert {:skip, reason} = first_pass["surfex"]
    assert reason =~ "git"
  end

  test "with the walk complete, the doc chain is inactive under test and nothing is ambiguous" do
    verdicts = EnvSet.classify(@roots_under_test, lock(), Graph.parse(@dot))

    for name <- @docs, do: assert(verdicts[name] == :inactive, "#{name} should be inactive")
    for name <- ~w(extla surfex jason telemetry), do: assert(verdicts[name] == :active)
    refute Enum.any?(verdicts, fn {_, v} -> v == :ambiguous end)
  end

  # The state extc's pipelines 2441/2442 were in: what the first pass says
  # before deps.get, and what the second pass must no longer say after it.
  test "before deps.get the doc chain is ambiguous — requested anyway, which is the fail-safe" do
    verdicts = EnvSet.classify(@roots_under_test, lock(), %{})
    for name <- @docs, do: assert(verdicts[name] == :ambiguous)
  end
end
