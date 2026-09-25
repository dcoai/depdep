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

    # The git dependency: a Mix project with no dependencies of its own, and
    # one module, so compiling it is real work with a `Generated forked app`.
    File.write!(Path.join(upstream, "mix.exs"), """
    defmodule Forked#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :forked, version: "0.1.0"]
    end
    """)

    File.mkdir_p!(Path.join(upstream, "lib"))

    File.write!(
      Path.join([upstream, "lib", "forked.ex"]),
      "defmodule Forked, do: def hi, do: :hi\n"
    )

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
      env: [{"DEPDEP_STORE", nil}, {"DEPDEP_ENDPOINT", nil}, {"DEPDEP_BUCKET", nil}],
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

  # #59: with no store nothing was restored, so every dependency is a miss —
  # the consumer's compile moved one line up, timed, and recorded beside the
  # build for a later --push.
  test "--compile-deps compiles the miss, times it, and leaves it for mix compile", ctx do
    assert {output, 0} = depdep(ctx.dir, ["--pull", "--mix-get", "--compile-deps"])
    assert output =~ "==> forked", "Mix's own boundary lines are forwarded"
    assert output =~ ~r/depdep: compiled 1 in \d+\.\ds/
    assert File.dir?(Path.join([ctx.dir, "_build", "test", "lib", "forked", "ebin"]))

    note = Path.join([ctx.dir, "_build", "test", ".depdep", "forked.compile"])
    assert {us, ""} = Integer.parse(File.read!(note))
    assert us > 0

    # The consumer's own compile then has nothing to do for the dependency.
    {out, 0} =
      System.cmd("mix", ["deps.compile"],
        cd: ctx.dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    refute out =~ "Generated forked app"
  end

  # The one place depdep may fail a job: it is the consumer's compile.
  test "a dependency that does not compile is the run's exit status", ctx do
    File.write!(
      Path.join([ctx.upstream, "lib", "forked.ex"]),
      "defmodule Forked do\n  def broken(\nend\n"
    )

    git = fn args ->
      {_, 0} = System.cmd("git", args, cd: ctx.upstream, stderr_to_stdout: true)
    end

    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "broken"])

    assert {output, status} = depdep(ctx.dir, ["--pull", "--mix-get", "--compile-deps"])
    assert status != 0
    assert output =~ "forked.ex", "the compile error is forwarded as Mix printed it"
  end

  test "--compile-deps without --mix-get is a usage error", ctx do
    assert {output, 2} = depdep(ctx.dir, ["--pull", "--compile-deps"])
    assert output =~ "--mix-get"
  end

  test "--mix-get without --pull is a usage error", ctx do
    assert {output, 2} = depdep(ctx.dir, ["--push", "--mix-get"])
    assert output =~ "--pull"
    assert output =~ "switches"
  end
end
