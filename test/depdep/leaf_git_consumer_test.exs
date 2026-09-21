defmodule Depdep.LeafGitConsumerTest do
  @moduledoc """
  extc's shape, end to end through the real modules (#81, from extc #170;
  #89 moved the inputs to Mix's).

  Two git dependencies: `extla`, which has hex children of its own, and
  `surfex`, a leaf with none. An `only: [:dev, :docs]` root brings in `ex_doc`
  and its chain, which nothing under `test` reaches. On v0.4.0 `surfex` was
  absent from the parsed `deps.tree` graph — only parents were keys — so it
  read as unknown, was skipped on every pass, kept the env walk incomplete,
  and left the six doc dependencies requested, missed, and handed to
  `mix deps.compile`, which refused them for `test`. Under `Depdep.Deps` the
  children are what Mix lists (`[]` for a fetched leaf) and env membership is
  Mix's list itself, so neither can happen. This pins the consumer case.
  """
  use ExUnit.Case, async: true

  import Depdep.LockFixture

  alias Depdep.{Deps, Key}

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

  # What `Mix.Dep.load_and_cache/0` lists for extc under MIX_ENV=test after
  # deps.get: the active set, each fetched dependency with its children. The
  # doc chain is not in it — Mix applied `only:` — and surfex's children are
  # `[]`, known and empty.
  defp after_deps_get do
    %{
      complete?: true,
      deps: %{
        "extla" => dep_info([{"jason", false}, {"telemetry", false}]),
        "surfex" => dep_info([]),
        "jason" => dep_info([]),
        "telemetry" => dep_info([])
      }
    }
  end

  test "after deps.get, the leaf is known and empty and the parent has its children" do
    deps = Deps.from_lock(lock(), after_deps_get())
    assert deps["surfex"].children == []
    assert deps["extla"].children == [{"jason", false}, {"telemetry", false}]
  end

  test "both git dependencies key after deps.get; before it, only the graph-less skip" do
    {:ok, keys} = Key.compute(Deps.from_lock(lock(), after_deps_get()), %{}, toolchain())
    assert {:key, _} = keys["surfex"]
    assert {:key, _} = keys["extla"]

    {:ok, first_pass} = Key.compute(Deps.from_lock(lock()), %{}, toolchain())
    assert {:skip, reason} = first_pass["surfex"]
    assert reason =~ "git"
  end

  test "after deps.get the doc chain is not for this env, exactly, and nothing is undecided" do
    deps = Deps.from_lock(lock(), after_deps_get())

    for name <- @docs, do: assert(deps[name].active? == false, "#{name} should be inactive")
    for name <- ~w(extla surfex jason telemetry), do: assert(deps[name].active? == true)
    refute Enum.any?(deps, fn {_, d} -> d.active? == nil end)
  end

  # The state extc's pipelines 2441/2442 were in: before deps.get nothing is
  # decided, so everything is requested — the fail-safe — and the second pass
  # settles it.
  test "before deps.get nothing is called inactive" do
    deps = Deps.from_lock(lock())
    for {_, d} <- deps, do: assert(d.active? == nil)
  end

  # bizex's shape (#79): a member whose closure arrives through a path
  # dependency. Mix's list has the path dependency and its children like
  # anything else, so its closure is active — by construction, not by a walk.
  test "a path dependency's closure is active because Mix lists it" do
    lock = Map.new([hex("ash_authentication", "4.15.0", ["assent"]), hex("assent", "0.2.0", [])])

    view = %{
      complete?: true,
      deps: %{
        "tenancy" => dep_info([{"ash_authentication", false}]),
        "ash_authentication" => dep_info([{"assent", false}]),
        "assent" => dep_info([])
      }
    }

    deps = Deps.from_lock(lock, view)
    assert deps["ash_authentication"].active? == true
    assert deps["assent"].active? == true
    refute Map.has_key?(deps, "tenancy"), "a path dependency is not a lock entry, so not a unit"
  end
end
