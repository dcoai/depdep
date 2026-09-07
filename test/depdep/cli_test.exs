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
end
