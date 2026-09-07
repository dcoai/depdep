defmodule Depdep.BuildPathTest do
  @moduledoc """
  Where a member compiles to, asked of the project rather than assumed.

  `async: false` because `Mix.Project.in_project/4` pushes and pops Mix's global
  project stack.
  """
  use ExUnit.Case, async: false

  alias Depdep.BuildPath

  defp project(build_path) do
    dir = Path.join(System.tmp_dir!(), "depdep-bp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # A unique module per fixture: the same name evaluated twice in one VM is a
    # redefinition, and these run in the same VM as each other.
    module = "Fixture#{System.unique_integer([:positive])}"
    setting = if build_path, do: ~s(      build_path: "#{build_path}",\n), else: ""

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :fixture,
          version: "0.1.0",
    #{setting}      elixir: "~> 1.15"
        ]
      end
    end
    """)

    dir
  end

  test "a project that says nothing builds where everyone builds" do
    assert BuildPath.for_project(project(nil), :test) == {:ok, "_build/test"}
  end

  # dco-tek/metresis: its storage adapter is compiled into the repo module, so
  # its two backends cannot share one build. Assuming `_build/<env>` meant
  # restoring into a directory Mix never read — a restore AND a full compile,
  # arrived at without a single error.
  test "a project that sets build_path builds where it says" do
    assert BuildPath.for_project(project("_build/sqlite"), :test) == {:ok, "_build/sqlite/test"}
  end

  # `Mix.Project.build_path/0` answers `<dir>/_build/sqlite/test`, not
  # `<dir>/_build/sqlite`. Appending the env again is the obvious bug here.
  test "the environment is not appended twice" do
    assert {:ok, path} = BuildPath.for_project(project("_build/sqlite"), :dev)
    refute path =~ "dev/dev"
    assert path == "_build/sqlite/dev"
  end

  # An object is rooted at the member, so a build outside it cannot be
  # represented — and writing one anyway would restore somewhere nobody asked
  # for.
  test "a build outside the project is refused, with a reason" do
    assert {:error, reason} = BuildPath.for_project(project("/tmp/somewhere-else"), :test)
    assert reason =~ "outside the project"
  end

  # The default is right for every project that does not set build_path, so it
  # is the default rather than a recovery.
  test "a directory with no mix.exs falls back rather than failing" do
    dir = Path.join(System.tmp_dir!(), "depdep-bp-none-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert BuildPath.for_project(dir, :test) == {:ok, "_build/test"}
  end
end
