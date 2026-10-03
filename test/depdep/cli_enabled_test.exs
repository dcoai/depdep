defmodule Depdep.CLIEnabledTest do
  @moduledoc """
  The off switch, decided before anything else is read.

  `async: false` because the environment is global: a test setting
  `DEPDEP_ENABLED` while another reads it would see the other's value.
  """
  use ExUnit.Case, async: false

  alias Depdep.CLI

  setup do
    original = System.get_env("DEPDEP_ENABLED")

    on_exit(fn ->
      if original,
        do: System.put_env("DEPDEP_ENABLED", original),
        else: System.delete_env("DEPDEP_ENABLED")
    end)

    :ok
  end

  defp with_value(nil), do: System.delete_env("DEPDEP_ENABLED")
  defp with_value(value), do: System.put_env("DEPDEP_ENABLED", value)

  describe "enabled? reads the variable" do
    # The regression guard that matters most: every consumer today sets nothing,
    # and must keep behaving exactly as it did.
    test "unset is enabled" do
      with_value(nil)
      assert CLI.enabled?() == {:ok, true}
    end

    # `Depdep.S3.env/1` already treats "" as not set, and a CI variable declared
    # without a value is ordinary. Same rule here rather than a second one.
    test "empty is enabled, like every other DEPDEP_ variable" do
      with_value("")
      assert CLI.enabled?() == {:ok, true}
    end

    test "true is enabled, whatever its case or spacing" do
      for value <- ["true", "TRUE", "True", "  true  "] do
        with_value(value)
        assert CLI.enabled?() == {:ok, true}, "#{inspect(value)} should be enabled"
      end
    end

    test "false is disabled, whatever its case or spacing" do
      for value <- ["false", "FALSE", "False", "  false  "] do
        with_value(value)
        assert CLI.enabled?() == {:ok, false}, "#{inspect(value)} should be disabled"
      end
    end
  end

  describe "a value it cannot read is refused, not guessed at" do
    # The switch exists to make a number trustworthy. `flase` quietly reading as
    # "enabled" would hand back a warm restore labelled as a cold build — the
    # class of wrong number #41 is open about.
    test "a typo is an error naming the value" do
      with_value("flase")
      assert {:error, message} = CLI.enabled?()
      assert message =~ "flase"
    end

    # A reader whose value was refused should not have to find the accepted
    # spellings elsewhere.
    test "the error names what it will accept" do
      with_value("nope")
      assert {:error, message} = CLI.enabled?()
      assert message =~ "true"
      assert message =~ "false"
    end

    # Plausible spellings someone will reach for. Each is refused rather than
    # silently meaning its opposite.
    test "neighbouring spellings are refused rather than assumed" do
      for value <- ["0", "1", "no", "yes", "off", "on"] do
        with_value(value)
        assert {:error, _} = CLI.enabled?(), "#{inspect(value)} should be refused"
      end
    end
  end

  # #137. `spec/01-goals-and-scope.md#failure-not-error` used to cite `main/1` for
  # the exit behaviour, which no test can call and then assert. It cites
  # `disposition/1` instead — the decision `main/1` wires — and this is what shows
  # the claim rather than asserting it.
  describe "disposition/1 decides before anything is read" do
    @tag verifies: "disposition-decides-before-reading"
    test "--help asks for the usage text, whatever else is set" do
      System.put_env("DEPDEP_ENABLED", "false")
      assert CLI.disposition(help: true) == :help
    end

    test "DEPDEP_ENABLED=false is a disposition, not an error, and carries the value" do
      System.put_env("DEPDEP_ENABLED", "FALSE")
      assert CLI.disposition([]) == {:disabled, "FALSE"}
    end

    test "a value it cannot read is an environment error, named as such" do
      System.put_env("DEPDEP_ENABLED", "perhaps")
      assert {:error, :environment, message} = CLI.disposition([])
      assert message =~ "perhaps"
    end

    test "unset and enabled is :run" do
      System.delete_env("DEPDEP_ENABLED")
      assert CLI.disposition([]) == :run
    end
  end
end
