defmodule Depdep.CLIMixGetIntegrationTest do
  @moduledoc """
  `--mix-get` end to end, in a real `elixir` process against a real git
  dependency — a bare repository on disk, so no network is involved.

  Run the way a consumer runs depdep (see `Depdep.CLIDisabledIntegrationTest`),
  because the thing under test is an exit status, and `main/1` halts.

  The store is deliberately NOT configured here. The line `--mix-get` replaces
  ran `mix deps.get` whether or not a store existed, so the property that
  matters most is that the fetch happens — and fails the job when it fails —
  with no store at all.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    base = Path.join(System.tmp_dir!(), "depdep-mixget-#{System.unique_integer([:positive])}")
    upstream = Path.join(base, "forked")
    dir = Path.join(base, "app")
    File.mkdir_p!(upstream)
    File.mkdir_p!(Path.join(dir, "config"))
    on_exit(fn -> File.rm_rf!(base) end)

    # The git dependency: a Mix project with no dependencies of its own.
    File.write!(Path.join(upstream, "mix.exs"), """
    defmodule Forked#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :forked, version: "0.1.0"]
    end
    """)

    git = fn args -> {_, 0} = System.cmd("git", args, cd: upstream, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "forked"])

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MixGetFixture#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :mix_get_fixture, version: "0.1.0", deps: deps()]
      defp deps, do: [{:forked, git: "file://#{upstream}", branch: "main"}]
    end
    """)

    File.write!(Path.join(dir, "mix.lock"), "%{}\n")
    File.write!(Path.join([dir, "config", "config.exs"]), "import Config\n")

    {:ok, dir: dir, upstream: upstream}
  end

  defp depdep(dir, args) do
    System.cmd(
      "elixir",
      ["-pa", Application.app_dir(:depdep, "ebin"), "-e", "Depdep.CLI.main(System.argv())", "--"] ++
        args,
      cd: dir,
      env: [{"DEPDEP_ENDPOINT", nil}, {"DEPDEP_BUCKET", nil}],
      stderr_to_stdout: true
    )
  end

  test "the fetch happens inside the pull, with its output forwarded", ctx do
    assert {output, 0} = depdep(ctx.dir, ["--pull", "--mix-get"])

    assert output =~ "store not configured"
    assert output =~ "forked", "mix deps.get's own lines are forwarded"
    assert File.dir?(Path.join([ctx.dir, "deps", "forked"]))
    assert File.read!(Path.join(ctx.dir, "mix.lock")) =~ "forked"
  end

  # The line this replaces failed the job when deps.get failed. So must this,
  # with the same status, and after saying why.
  test "a failing deps.get is the run's exit status", ctx do
    File.write!(Path.join(ctx.dir, "mix.exs"), """
    defmodule MixGetFailing#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :mix_get_fixture, version: "0.1.0", deps: deps()]
      defp deps, do: [{:forked, git: "file://#{ctx.upstream}-does-not-exist", branch: "main"}]
    end
    """)

    assert {output, status} = depdep(ctx.dir, ["--pull", "--mix-get"])
    assert status != 0
    assert output =~ "mix deps.get failed"
  end

  test "without --mix-get nothing is fetched, as before", ctx do
    assert {_output, 0} = depdep(ctx.dir, ["--pull"])
    refute File.dir?(Path.join([ctx.dir, "deps", "forked"]))
  end

  test "--mix-get without --pull is a usage error", ctx do
    assert {output, 2} = depdep(ctx.dir, ["--push", "--mix-get"])
    assert output =~ "--pull"
    assert output =~ "switches"
  end
end
