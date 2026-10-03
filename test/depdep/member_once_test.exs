defmodule Depdep.MemberOnceTest do
  @moduledoc """
  One `mix.exs` compiles once a run, whichever path loaded it first (#132, from
  #109).

  `Mix.Project.in_project/4` caches by app atom, so asking about a directory under
  a different atom than Mix used compiles its `mix.exs` again and — the module from
  Mix's load still being present — prints `warning: redefining module
  X.MixProject`. In a poncho whose members are each other's path dependencies that
  is one warning per member per run: nine on `dco-tek/bizex`, about fifty lines a
  job.

  **Asserted on the symptom, not the memo's internals.** The symptom is observable
  in output, so checking it directly keeps this honest if the caching strategy
  changes again — which it has once already.

  `async: false`: asking Mix moves the VM's working directory and pushes its
  project stack.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Depdep.{Deps, Member}

  setup do
    base = Path.join(System.tmp_dir!(), "member-once-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    leaf = Path.join(base, "leaf")
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(leaf, "config"))
    on_exit(fn -> File.rm_rf!(base) end)

    # The poncho shape that produces the warning: a member that path-depends on
    # another member, so Mix loads the leaf's project under `:member_once_leaf`
    # while depdep later asks about that same directory as a member of its own.
    File.write!(Path.join(leaf, "mix.exs"), """
    defmodule MemberOnceLeaf.MixProject do
      use Mix.Project
      def project, do: [app: :member_once_leaf, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule MemberOnceRoot#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :member_once_root, version: "0.1.0", deps: deps()]
      defp deps, do: [{:member_once_leaf, path: "../leaf"}]
    end
    """)

    for dir <- [root, leaf],
        do: File.write!(Path.join([dir, "config", "config.exs"]), "import Config\n")

    File.write!(Path.join(root, "mix.lock"), "%{}\n")
    File.write!(Path.join(leaf, "mix.lock"), "%{}\n")

    %{root: root, leaf: leaf}
  end

  @tag verifies: "mix-exs-compiles-once-per-run"
  test "asking about a path-dependency member prints no redefining warning", ctx do
    output =
      capture_io(:stderr, fn ->
        # The root first, as a run does: its converge loads the leaf's project.
        Deps.converged(ctx.root, :test)
        # Then the leaf as a member in its own right.
        Deps.converged(ctx.leaf, :test)
      end)

    refute output =~ "redefining module",
           "depdep recompiled a mix.exs Mix had already loaded:\n" <> output
  end

  @tag verifies: "mix-exs-compiles-once-per-run"
  test "the root's converge records Mix's own app name for the member", ctx do
    Deps.converged(ctx.root, :test)

    assert Member.remembered(ctx.leaf) == :member_once_leaf
  end

  @tag verifies: "mix-exs-compiles-once-per-run"
  test "remember/2 and remembered/1 are a round trip, keyed by the expanded path", ctx do
    assert Member.remembered(ctx.leaf) == nil

    Member.remember(Path.join(ctx.leaf, "."), :some_app)

    assert Member.remembered(ctx.leaf) == :some_app
    assert Member.remembered(ctx.root) == nil
  end

  test "a directory Mix never loaded has no memo, and asking still works", ctx do
    assert Member.remembered(ctx.root) == nil
    assert is_list(Deps.converged(ctx.root, :test))
  end

  # `ask/3` is what every question about a member goes through, and what moves the
  # VM's working directory for the duration.
  test "ask/3 runs the function inside the member's own project", ctx do
    assert Member.ask(ctx.leaf, :test, fn -> Mix.Project.config()[:app] end) ==
             :member_once_leaf

    assert Member.ask(ctx.leaf, :test, fn -> File.cwd!() end) == Path.expand(ctx.leaf)
  end

  @tag verifies: "the-converge-is-mixs-own-list"
  test "the converge returns Mix's own structs, the path dependency among them", ctx do
    deps = Deps.converged(ctx.root, :test)

    assert Enum.any?(deps, fn d -> match?(%Mix.Dep{app: :member_once_leaf}, d) end)
    assert Enum.all?(deps, fn d -> match?(%Mix.Dep{}, d) end)
  end
end
