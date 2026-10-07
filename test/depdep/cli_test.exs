defmodule Depdep.CLITest do
  @moduledoc """
  The command line's one job before it does anything: understand what it was
  asked, or say so.

  `main/1` halts, so what is exercised here is `parse/1` — the decision — rather
  than the exit itself.
  """
  use ExUnit.Case, async: true

  alias Depdep.CLI

  describe "parse/1 accepts a valid invocation" do
    # The regression guard. This runs at the front of every consumer's pipeline,
    # so a valid invocation behaving differently is the expensive failure here.
    test "a plain pull" do
      assert {:ok, opts} = CLI.parse(["--pull"])
      assert opts[:pull]
      assert opts[:root] == File.cwd!()
      assert opts[:env] == :test
    end

    test "repeatable and valued switches" do
      assert {:ok, opts} =
               CLI.parse([
                 "--push",
                 "--project",
                 "a",
                 "--project",
                 "b",
                 "--exclude",
                 "tools/eval",
                 "--env",
                 "dev"
               ])

      assert Keyword.get_values(opts, :project) == ["a", "b"]
      assert opts[:exclude] == "tools/eval"
      assert opts[:env] == :dev
    end

    test "the provider switches" do
      assert {:ok, opts} =
               CLI.parse(["--pull", "--provider", "apt", "--package", "git", "--repo", "u"])

      assert Keyword.get_values(opts, :provider) == ["apt"]
      assert Keyword.get_values(opts, :package) == ["git"]
    end

    test "--help" do
      assert {:ok, opts} = CLI.parse(["--help"])
      assert opts[:help]
    end

    # spec/09-cli.md#switches. Both directions, because each catches a different
    # mistake: a switch added to @switches and not documented is invisible to a
    # reader, and a switch documented but never accepted is a promise the code
    # does not keep. #119 wrote the spec's table from @switches, so this is what
    # keeps all three in step.
    @tag verifies: "cli-switches-documented"
    test "every switch is documented, and every documented switch is accepted" do
      {usage, 0} =
        System.cmd(
          "elixir",
          ["-pa", Application.app_dir(:depdep, "ebin"), "-e", "Depdep.CLI.main([\"--help\"])"],
          stderr_to_stdout: true
        )

      switches =
        Depdep.CLI.switches()
        |> Keyword.keys()
        |> Enum.map(&("--" <> String.replace(to_string(&1), "_", "-")))

      for switch <- switches do
        assert usage =~ switch, "#{switch} is accepted but not in --help"
      end

      documented =
        ~r/--[a-z][a-z-]+/
        |> Regex.scan(usage)
        |> List.flatten()
        |> Enum.uniq()

      for switch <- documented do
        assert switch in switches, "#{switch} is in --help but not accepted"
      end
    end

    test "--help documents both forms of the store and of metresis (#88)" do
      {text, 0} =
        System.cmd(
          "elixir",
          ["-pa", Application.app_dir(:depdep, "ebin"), "-e", "Depdep.CLI.main([\"--help\"])"],
          stderr_to_stdout: true
        )

      assert text =~ "DEPDEP_STORE=s3://ACCESS_KEY@host:port/bucket"
      assert text =~ "DEPDEP_ENDPOINT"
      assert text =~ "DEPDEP_METRESIS (or DEPDEP_METRESIS_URL)"
    end
  end

  describe "parse/1 refuses what it does not understand" do
    # dco-tek/metresis #86: `--provider apt` against a tag that predated
    # providers was dropped into `invalid`, the mix provider ran instead, and it
    # died evaluating config/config.exs — which reads as a config bug. Silence is
    # what made that expensive.
    test "an unknown switch is named" do
      assert {:error, [problem]} = CLI.parse(["--pull", "--no-such-flag"])
      assert problem =~ "--no-such-flag"
      assert problem =~ "not a switch"
    end

    # OptionParser reports both as `{"--thing", nil}`, so this distinction has to
    # be made deliberately. A reader whose value is missing should not be sent
    # hunting for a typo.
    test "a malformed value says the VALUE was wrong, not the name" do
      assert {:error, [problem]} = CLI.parse(["--env"])
      assert problem =~ "--env"
      assert problem =~ "value"
      refute problem =~ "not a switch"
    end

    @tag verifies: "cli-parse-reports-every-problem"
    test "every problem is reported, not only the first" do
      assert {:error, problems} = CLI.parse(["--nope", "--also-nope"])
      assert length(problems) == 2
    end

    # A flag from a newer depdep than the pinned tag is the case that matters
    # most: it is indistinguishable from a typo to the parser, and both should
    # stop the run rather than quietly change what it does.
    test "a switch this version does not have yet is refused like any other" do
      assert {:error, [problem]} = CLI.parse(["--pull", "--provider-from-the-future"])
      assert problem =~ "this version"
    end
  end

  # #60: `--mix-get` is a step inside a pull, for the one provider that has a
  # `deps.get`. Any other combination is someone editing an invocation and
  # getting less than they asked for, which is the case worth stopping.
  describe "combination/2" do
    @tag verifies: "cli-combinations-refused"
    test "--mix-get needs --pull" do
      {:ok, opts} = CLI.parse(["--push", "--mix-get"])
      assert {:error, message} = CLI.combination(opts, [Depdep.Provider.Mix])
      assert message =~ "--pull"
    end

    # #135: a diagnostic for what a PULL restored, so there is nothing for it to
    # explain in a push, a plan, a report or a sweep.
    test "--explain-rebuilt needs --pull" do
      {:ok, opts} = CLI.parse(["--explain-rebuilt", "--push"])

      assert {:error, reason} = CLI.combination(opts, [Depdep.Provider.Mix])
      assert reason =~ "--explain-rebuilt"
      assert reason =~ "--pull"
    end

    test "--explain-rebuilt with --pull is fine" do
      {:ok, opts} = CLI.parse(["--explain-rebuilt", "--pull"])
      assert CLI.combination(opts, [Depdep.Provider.Mix]) == :ok
    end

    # #150, the fourth rail. `--confirm` is the only irreversible thing depdep does,
    # and the bucket it acts on can come from an inherited environment variable —
    # which is how the group's credentials reached depdep's own CI in #148.
    test "--confirm needs --bucket" do
      {:ok, opts} = CLI.parse(["--sweep", "--confirm"])
      assert {:error, message} = CLI.combination(opts, [Depdep.Provider.Mix])
      assert message =~ "--bucket"
      assert message =~ "name the store"
    end

    # A dry run changes nothing, so it asks for nothing. Making the safe path
    # harder would push an operator toward the destructive one.
    test "a dry run needs no --bucket" do
      {:ok, opts} = CLI.parse(["--sweep"])
      assert CLI.combination(opts, [Depdep.Provider.Mix]) == :ok
    end

    test "--bucket without --confirm is refused rather than ignored" do
      {:ok, opts} = CLI.parse(["--sweep", "--bucket", "some-store"])
      assert {:error, message} = CLI.combination(opts, [Depdep.Provider.Mix])
      assert message =~ "--confirm"
    end

    test "--confirm with --bucket is fine" do
      {:ok, opts} = CLI.parse(["--sweep", "--confirm", "--bucket", "some-store"])
      assert CLI.combination(opts, [Depdep.Provider.Mix]) == :ok
    end

    test "--mix-get is for the mix provider only" do
      {:ok, opts} = CLI.parse(["--pull", "--mix-get", "--provider", "apt"])
      assert {:error, message} = CLI.combination(opts, [Depdep.Provider.Apt])
      assert message =~ "mix provider"

      {:ok, opts} = CLI.parse(["--pull", "--mix-get", "--provider", "mix", "--provider", "apt"])
      assert {:error, _} = CLI.combination(opts, [Depdep.Provider.Mix, Depdep.Provider.Apt])
    end

    test "--pull --mix-get with the default provider is fine, and so is everything without it" do
      {:ok, opts} = CLI.parse(["--pull", "--mix-get"])
      assert CLI.combination(opts, [Depdep.Provider.Mix]) == :ok

      {:ok, opts} = CLI.parse(["--push", "--provider", "apt"])
      assert CLI.combination(opts, [Depdep.Provider.Apt]) == :ok
    end
  end

  # #54: one sentence used to follow every error in `main/1`'s branch, and it
  # named switches — so `DEPDEP_ENABLED=flase` was told its SWITCH was wrong.
  # The hint is chosen per class here so a class added later must pick one.
  describe "hint/1 follows the error, not the branch" do
    # Load-bearing wording (#31, metresis #86): consumers and README quote it.
    @tag verifies: "spec/09-cli.md#hints"
    test "a switch problem keeps its exact sentence" do
      assert CLI.hint(:switch) == "run with --help for the switches this version understands"
    end

    test "an environment problem is not called a switch" do
      hint = CLI.hint(:environment)
      refute hint =~ "switch"
      assert hint =~ "environment variable"
      assert hint =~ "--help"
    end

    test "there is no default: an unknown class is a bug, not a hint" do
      assert_raise FunctionClauseError, fn -> CLI.hint(:something_new) end
    end
  end
end
