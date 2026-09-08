defmodule Depdep.ConfigTest do
  @moduledoc """
  Compile-time config, evaluated under the member's own project.

  `async: false`: `Depdep.Member` pushes and pops Mix's global project stack,
  and the redefine-warning test captures the VM's stderr.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Depdep.Config

  # A member whose config calls into its own mix.exs — dco-tek/metresis chooses
  # its Ecto adapter that way — and asks Mix where it builds, which is how both
  # metresis and dco-tek/bizex set esbuild's NODE_PATH.
  defp member(flavour, build_path) do
    dir = Path.join(System.tmp_dir!(), "depdep-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "config"))
    on_exit(fn -> File.rm_rf!(dir) end)

    # A unique module per fixture: the same name evaluated twice in one VM is a
    # redefinition, and these run in the same VM as each other.
    module = "Fixture#{System.unique_integer([:positive])}"

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [app: :fixture, version: "0.1.0", build_path: "#{build_path}", elixir: "~> 1.15"]
      end

      def flavour, do: "#{flavour}"
    end
    """)

    File.write!(Path.join([dir, "config", "config.exs"]), """
    import Config

    config :fixture,
      flavour: #{module}.MixProject.flavour(),
      build: Mix.Project.build_path()
    """)

    dir
  end

  defp digest(dir, root \\ "/nowhere") do
    assert %{"fixture" => digest} = Config.read(dir, :test, root)
    digest
  end

  # metresis, 2026-09-08: `Metresis.MixProject.repo_adapter/0 is undefined` on
  # every mix-provider run, because config was evaluated with nothing on Mix's
  # project stack. Its `|| echo` guard then turned the crash into a green job
  # that restored nothing.
  test "config that calls a function from its own mix.exs is keyed, not a crash" do
    assert is_binary(digest(member("vanilla", "_build")))
  end

  test "the function's answer is part of the digest" do
    refute digest(member("vanilla", "_build")) == digest(member("chocolate", "_build"))
  end

  # `Mix.Project.build_path/0` with no project loaded answers from the CURRENT
  # DIRECTORY, so bizex's esbuild digest used to depend on whether depdep was run
  # from the poncho root or the member — the machine-dependence this module's
  # own moduledoc warns consumers about. Under the member's project it answers
  # the member's build path whatever the cwd.
  test "a config that asks for the build path digests the same from any cwd" do
    dir = member("vanilla", "_build/flavoured")

    elsewhere =
      Path.join(System.tmp_dir!(), "depdep-cfg-cwd-#{System.unique_integer([:positive])}")

    File.mkdir_p!(elsewhere)
    on_exit(fn -> File.rm_rf!(elsewhere) end)

    from_here = digest(dir)
    from_elsewhere = File.cd!(elsewhere, fn -> digest(dir) end)

    assert from_here == from_elsewhere
  end

  test "the member's build path, not the default, is what the config sees" do
    refute digest(member("vanilla", "_build/flavoured")) == digest(member("vanilla", "_build"))
  end

  # Both questions depdep asks of a member load its mix.exs. A fresh app name
  # per question would compile it twice and print `redefining module` into every
  # consumer's log, once per member per run.
  test "asking for the build path and the config compiles mix.exs once: nothing on stderr" do
    dir = member("vanilla", "_build/flavoured")

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, "_build/flavoured/test"} = Depdep.BuildPath.for_project(dir, :test)
        assert %{"fixture" => _} = Config.read(dir, :test, "/nowhere")
      end)

    assert stderr == ""
  end

  test "a member with no config at all is an empty map" do
    dir = Path.join(System.tmp_dir!(), "depdep-cfg-none-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert Config.read(dir, :test, "/nowhere") == %{}
  end
end
