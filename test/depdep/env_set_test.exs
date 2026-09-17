defmodule Depdep.EnvSetTest do
  @moduledoc """
  `classify/3` is pure and is most of the module; `declared/2` asks Mix and so
  runs `async: false` for the reason `Depdep.Provider.MixTest` gives — asking a
  member loads its `mix.exs` and moves the VM's working directory.
  """
  use ExUnit.Case, async: false

  alias Depdep.EnvSet

  defp hex(name, children) do
    deps =
      Enum.map(children, fn
        {child, :optional} -> {child, ">= 0.0.0", [hex: child, repo: "hexpm", optional: true]}
        child -> {child, ">= 0.0.0", [hex: child, repo: "hexpm", optional: false]}
      end)

    {:hex, name, "1.0.0", "inner", [:mix], deps, "hexpm", "outer"}
  end

  defp git(name), do: {:git, "https://example.invalid/#{name}.git", "88ab3a0d", [tag: "v1"]}

  # visualize's shape: a prod dependency with a child, and a dev-only
  # dependency with a chain of its own that nothing in prod reaches.
  defp lock do
    %{
      "jason" => hex(:jason, [{:decimal, :optional}]),
      "decimal" => hex(:decimal, []),
      "ex_doc" => hex(:ex_doc, [:makeup, :earmark_parser]),
      "makeup" => hex(:makeup, [:nimble_parsec]),
      "earmark_parser" => hex(:earmark_parser, []),
      "nimble_parsec" => hex(:nimble_parsec, [])
    }
  end

  describe "classify/3" do
    test "a dev-only chain is inactive under test, and active under dev" do
      under_test = EnvSet.classify(["jason"], lock(), %{})
      assert under_test["jason"] == :active
      assert under_test["ex_doc"] == :inactive
      assert under_test["makeup"] == :inactive
      assert under_test["nimble_parsec"] == :inactive

      under_dev = EnvSet.classify(["jason", "ex_doc"], lock(), %{})
      assert under_dev["ex_doc"] == :active
      assert under_dev["makeup"] == :active
      assert under_dev["nimble_parsec"] == :active
    end

    # Mix includes an optional dependency only when something reaches it
    # non-optionally. Here nothing does, so jason compiles without decimal.
    test "an optional child reached only optionally is inactive" do
      assert EnvSet.classify(["jason"], lock(), %{})["decimal"] == :inactive
    end

    test "an optional child is active once any non-optional edge reaches it" do
      lock = Map.put(lock(), "money", hex(:money, [:decimal]))
      assert EnvSet.classify(["jason", "money"], lock, %{})["decimal"] == :active
    end

    test "a top-level optional dependency is a root: the project itself builds it" do
      assert EnvSet.classify(["jason", "decimal"], lock(), %{})["decimal"] == :active
    end

    # The fail-safe direction. Before deps.get a git dependency's children are
    # unknown, so an unreached entry may be one of them — and calling it
    # inactive would mean never pulled, never pushed, and reported as intended.
    test "an unreached entry is ambiguous, not inactive, while a git child list is unknown" do
      lock = Map.put(lock(), "forked", git(:forked))
      verdicts = EnvSet.classify(["jason", "forked"], lock, %{})

      assert verdicts["forked"] == :active
      assert verdicts["jason"] == :active
      assert verdicts["ex_doc"] == :ambiguous
      assert verdicts["nimble_parsec"] == :ambiguous
    end

    test "the graph resolves the ambiguity exactly" do
      lock = Map.put(lock(), "forked", git(:forked))
      graph = %{"forked" => ["earmark_parser"]}
      verdicts = EnvSet.classify(["jason", "forked"], lock, graph)

      assert verdicts["earmark_parser"] == :active
      assert verdicts["ex_doc"] == :inactive
      assert verdicts["makeup"] == :inactive
    end

    # A git dependency that is itself dev-only leaves nothing unknown on the
    # active side, so the walk is complete and the verdicts are exact.
    test "an inactive git dependency does not make the rest ambiguous" do
      lock = Map.put(lock(), "forked", git(:forked))
      verdicts = EnvSet.classify(["jason"], lock, %{})

      assert verdicts["forked"] == :inactive
      assert verdicts["ex_doc"] == :inactive
    end

    test "a direct dependency absent from the lock is ignored rather than raised on" do
      assert EnvSet.classify(["jason", "not_locked"], lock(), %{})["jason"] == :active
    end

    test "unknown declarations make everything active — the behaviour before this existed" do
      verdicts = EnvSet.classify(:unknown, lock(), %{})
      assert Enum.all?(verdicts, fn {_, v} -> v == :active end)
      assert map_size(verdicts) == map_size(lock())
    end
  end

  describe "declared/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-envset-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "reads only: in each of Mix's three spellings", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule DepdepEnvSetFixture#{System.unique_integer([:positive])}.MixProject do
        use Mix.Project
        def project, do: [app: :depdep_envset_fixture, version: "0.1.0", deps: deps()]
        defp deps do
          [
            {:jason, "~> 1.4"},
            {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
            {:ex_doc, "~> 0.34", only: :dev},
            {:explorer, only: :test},
            {:local, path: "../local"}
          ]
        end
      end
      """)

      assert EnvSet.declared(dir, :test) == ["credo", "explorer", "jason", "local"]
      assert EnvSet.declared(dir, :dev) == ["credo", "ex_doc", "jason", "local"]
      assert EnvSet.declared(dir, :prod) == ["jason", "local"]
    end

    test "no mix.exs is :unknown, never an empty list", %{dir: dir} do
      assert EnvSet.declared(dir, :test) == :unknown
    end
  end
end
