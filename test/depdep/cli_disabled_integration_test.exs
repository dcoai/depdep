defmodule Depdep.CLIDisabledIntegrationTest do
  @moduledoc """
  The off switch end to end, in a real `elixir` process.

  `Depdep.CLI.main/1` halts, so the exit code — the thing a pipeline actually
  reacts to — cannot be observed in-process. These run depdep the way a consumer
  does: plain `elixir`, depdep's beams on the path in place of `Mix.install`,
  the member as the working directory.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  # A project depdep cannot read: its config raises. Under normal operation that
  # is a non-zero exit by design (`Depdep`'s "limit of that promise"), which is
  # what makes it the right fixture — the disabled run must not reach it.
  setup do
    dir = Path.join(System.tmp_dir!(), "depdep-off-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "config"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule OffFixture#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :off_fixture, version: "0.1.0", elixir: "~> 1.15"]
    end
    """)

    File.write!(Path.join(dir, "mix.lock"), "%{}\n")

    File.write!(Path.join([dir, "config", "config.exs"]), """
    import Config
    raise "this project's config cannot be read"
    """)

    {:ok, dir: dir}
  end

  # The four store variables are set throughout: "disabled" must not be reached
  # by way of "not configured", which would pass these tests for the wrong reason.
  defp depdep(dir, args, enabled) do
    env =
      [
        # The suite is hermetic: an ambient DEPDEP_STORE would make depdep
        # refuse both forms at once (#93), so clear it for the child.
        {"DEPDEP_STORE", nil},
        {"DEPDEP_ENDPOINT", "http://127.0.0.1:1"},
        {"DEPDEP_BUCKET", "b"},
        {"DEPDEP_ACCESS_KEY", "a"},
        {"DEPDEP_SECRET_KEY", "s"},
        {"DEPDEP_ENABLED", enabled}
      ]

    System.cmd(
      "elixir",
      [
        "-pa",
        Application.app_dir(:depdep, "ebin"),
        "-e",
        "Depdep.CLI.main(System.argv())" | ["--" | args]
      ],
      cd: dir,
      env: env,
      stderr_to_stdout: true
    )
  end

  # Proves the fixture is genuinely fatal. Without this the disabled assertions
  # below would pass against a project that was never going to fail.
  test "the fixture really does fail when depdep is enabled", ctx do
    assert {output, status} = depdep(ctx.dir, ["--pull"], nil)
    assert status != 0
    assert output =~ "config"
  end

  # The kill-switch property: an off switch that needs depdep to work is no use
  # on the day depdep does not.
  test "disabled exits 0 without reading the project at all", ctx do
    assert {output, 0} = depdep(ctx.dir, ["--pull"], "false")
    assert output =~ "disabled by DEPDEP_ENABLED=false"
    refute output =~ "cannot be read"
  end

  test "every mode is off, not just the transfers", ctx do
    for mode <- ["--pull", "--push", "--plan", "--report", "--sweep"] do
      assert {output, 0} = depdep(ctx.dir, [mode], "false"), "#{mode} should exit 0"
      assert output =~ "disabled by DEPDEP_ENABLED=false"
      refute output =~ "pulled", "#{mode} should not report a transfer"
    end
  end

  # Asking what the switches are is a documentation request. Answering it with an
  # exit code because the environment holds a typo is unhelpful at exactly the
  # moment help was asked for.
  test "--help answers even when disabled", ctx do
    assert {output, 0} = depdep(ctx.dir, ["--help"], "false")
    assert output =~ "--pull"
  end

  test "--help answers even when the value is unreadable", ctx do
    assert {output, 0} = depdep(ctx.dir, ["--help"], "flase")
    assert output =~ "--pull"
  end

  # A value depdep cannot read is a usage error, like an unknown switch.
  test "an unreadable value exits 2 and names the value", ctx do
    assert {output, 2} = depdep(ctx.dir, ["--pull"], "flase")
    assert output =~ "flase"
    assert output =~ "true"
  end

  # Enabled must remain exactly what it was: this fixture has an empty lock, so
  # a normal run reports a transfer of nothing rather than refusing to start.
  test "enabled still runs, with a summary line", ctx do
    File.write!(Path.join(ctx.dir, "config/config.exs"), "import Config\n")
    assert {output, 0} = depdep(ctx.dir, ["--pull"], "true")
    assert output =~ "depdep: pulled"
    refute output =~ "disabled"
  end
end
