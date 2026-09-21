defmodule Depdep.DepsTest do
  @moduledoc """
  `Depdep.Deps` through Mix, on real scratch projects: a hex dependency that
  is not fetched, a git dependency before and after fetch, a path dependency,
  and an `only: :dev` dependency under `test`.

  `async: false`: asking Mix about a member pushes Mix's project stack and
  moves the VM's working directory (`Depdep.Member`).
  """
  use ExUnit.Case, async: false

  alias Depdep.Deps

  setup do
    base = Path.join(System.tmp_dir!(), "depdep-deps-#{System.unique_integer([:positive])}")
    upstream = Path.join(base, "leafy")
    sibling = Path.join(base, "sibling")
    app = Path.join(base, "app")
    Enum.each([upstream, sibling, app], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(base) end)

    File.write!(Path.join(upstream, "mix.exs"), """
    defmodule Leafy#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :leafy, version: "0.1.0"]
    end
    """)

    git = fn args -> {_, 0} = System.cmd("git", args, cd: upstream, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "leafy"])

    File.write!(Path.join(sibling, "mix.exs"), """
    defmodule Sibling#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :sibling, version: "0.1.0", deps: [{:decimal, "~> 2.0"}]]
    end
    """)

    File.write!(Path.join(app, "mix.exs"), """
    defmodule DepsFixture#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :deps_fixture, version: "0.1.0", deps: deps()]
      defp deps do
        [
          {:jason, "~> 1.4"},
          {:ex_doc, "~> 0.30", only: :dev, runtime: false},
          {:leafy, git: "file://#{upstream}", branch: "main"},
          {:sibling, path: "../sibling"}
        ]
      end
    end
    """)

    # The lock Mix would have written: jason, decimal (through sibling),
    # ex_doc and its one child, and the git entry.
    File.write!(Path.join(app, "mix.lock"), """
    %{
      "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"},
      "decimal": {:hex, :decimal, "2.1.1", "innerdec", [:mix], [], "hexpm", "outerdec"},
      "ex_doc": {:hex, :ex_doc, "0.38.2", "innerexdoc", [:mix], [{:earmark_parser, "~> 1.4", [hex: :earmark_parser, repo: "hexpm", optional: false]}], "hexpm", "outerexdoc"},
      "earmark_parser": {:hex, :earmark_parser, "1.4.44", "innerep", [:mix], [], "hexpm", "outerep"},
      "leafy": {:git, "file://#{upstream}", "0000000000000000000000000000000000000000", [branch: "main"]}
    }
    """)

    %{app: app, upstream: upstream}
  end

  test "before anything is fetched: children from the lock, nothing inactive, git unknown", ctx do
    {:ok, deps} = Deps.read(ctx.app, :test)

    assert deps["jason"].children == []
    assert deps["ex_doc"].children == [{"earmark_parser", false}]
    assert deps["leafy"].children == :unknown
    for {_, d} <- deps, do: assert(d.active? == nil)
    refute Map.has_key?(deps, "sibling")
  end

  test "after the git dependency is fetched: its children are Mix's, and the env is exact", ctx do
    # What `mix deps.get` leaves: the git checkout under deps/. Hex entries in
    # this fixture are not fetched, so Mix's list stays incomplete — the
    # verdict must still be nil.
    {_, 0} =
      System.cmd(
        "git",
        ["clone", "-q", "-b", "main", "file://#{ctx.upstream}", Path.join(ctx.app, "deps/leafy")],
        stderr_to_stdout: true
      )

    {:ok, deps} = Deps.read(ctx.app, :test)
    assert deps["leafy"].children == []
    assert deps["leafy"].active? == nil
  end

  test "the build options are the declaration's, defaulting to :prod", ctx do
    File.write!(Path.join(ctx.app, "mix.exs"), """
    defmodule DepsFixtureOpts#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :deps_fixture, version: "0.1.0", deps: deps()]
      defp deps, do: [{:jason, "~> 1.4", env: :dev, system_env: [{"CC", "clang"}]}]
    end
    """)

    File.write!(Path.join(ctx.app, "mix.lock"), """
    %{"jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"}}
    """)

    {:ok, deps} = Deps.read(ctx.app, :test)
    assert deps["jason"].env == :dev
    assert deps["jason"].system_env == [{"CC", "clang"}]
    assert deps["jason"].compile == nil
  end

  test "a member with no mix.exs has no env rule: everything active, children from the lock",
       ctx do
    File.rm!(Path.join(ctx.app, "mix.exs"))
    {:ok, deps} = Deps.read(ctx.app, :test)
    assert deps["jason"].active? == true
    assert deps["jason"].children == []
    assert deps["leafy"].children == :unknown
  end

  # `%Mix.Dep{}` is internal to Mix. These are the fields `Depdep.Deps` reads;
  # if one goes, this fails on the version bump rather than at a consumer.
  test "the %Mix.Dep{} fields depdep reads exist" do
    fields = Map.keys(%Mix.Dep{})
    for field <- Deps.mix_dep_fields(), do: assert(field in fields, "%Mix.Dep{} has no #{field}")
    assert function_exported?(Mix.Dep.Converger, :converge, 1)
    assert function_exported?(Mix.Dep, :clear_cached, 0)
    assert function_exported?(Mix.Local, :append_archives, 0)
    assert function_exported?(Mix.Dep, :available?, 1)
    assert function_exported?(Mix.Dep, :format_status, 1)
  end
end
