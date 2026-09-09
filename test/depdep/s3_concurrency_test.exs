defmodule Depdep.S3ConcurrencyTest do
  @moduledoc """
  The concurrency instrument (#53), and the rules that keep a measurement honest.

  `async: false` because the environment is global: a test setting
  `DEPDEP_CONCURRENCY` while another reads it would see the other's value.
  """
  use ExUnit.Case, async: false

  alias Depdep.CLI
  alias Depdep.S3

  setup do
    original = System.get_env("DEPDEP_CONCURRENCY")

    on_exit(fn ->
      if original,
        do: System.put_env("DEPDEP_CONCURRENCY", original),
        else: System.delete_env("DEPDEP_CONCURRENCY")
    end)

    :ok
  end

  defp with_value(nil), do: System.delete_env("DEPDEP_CONCURRENCY")
  defp with_value(value), do: System.put_env("DEPDEP_CONCURRENCY", value)

  describe "unset is the derivation, unchanged" do
    # The regression guard that matters most: every consumer today sets nothing,
    # and must keep behaving exactly as it did in v0.2.0.
    test "unset derives from the scheduler count, bounded at both ends" do
      with_value(nil)
      assert S3.concurrency() >= 8
      assert S3.concurrency() <= 32
    end

    # `env/1` and `CLI.enabled?/0` already treat "" as not set, and a CI variable
    # declared without a value is ordinary. Same rule here rather than a third.
    test "empty is unset, like every other DEPDEP_ variable" do
      with_value("")
      assert S3.concurrency() == S3.concurrency_setting() |> elem(1)
      assert S3.concurrency() >= 8
    end

    test "whitespace only is unset too, since it trims to empty" do
      with_value("   ")
      assert S3.concurrency() >= 8
      assert S3.concurrency() <= 32
    end
  end

  describe "an explicit value is used as given" do
    # THE test of this work item. Routing the override through the derived
    # `max(8)` would run eight transfers and report the run as serial — the
    # measurement would look real and be wrong, which is the whole defect #41 is
    # open about. Without this the variable is decorative.
    test "the derived clamp does NOT apply: 1 is 1, never 8" do
      with_value("1")
      assert S3.concurrency() == 1
    end

    test "a value inside the derived range is taken literally" do
      with_value("16")
      assert S3.concurrency() == 16
    end

    test "a value above the derived clamp but under the ceiling is honoured" do
      with_value("64")
      assert S3.concurrency() == 64
    end

    test "surrounding whitespace is trimmed, as DEPDEP_ENABLED does" do
      with_value("  4  ")
      assert S3.concurrency() == 4
    end
  end

  describe "a value it cannot read is refused, not guessed at" do
    # `DEPDEP_ENABLED=flase` quietly meaning "enabled" would hand back a warm
    # restore labelled cold. `DEPDEP_CONCURRENCY=one` quietly meaning 16 would
    # hand back a concurrent run labelled serial — the same defect, measuring
    # the same claim, so it gets the same treatment.
    test "a non-integer is an error naming the value" do
      with_value("one")
      assert {:error, message} = S3.concurrency_setting()
      assert message =~ "one"
    end

    test "zero and negatives are refused rather than meaning the derivation" do
      for value <- ["0", "-1", "-32"] do
        with_value(value)
        assert {:error, _} = S3.concurrency_setting(), "#{inspect(value)} should be refused"
      end
    end

    test "a float is refused rather than truncated" do
      with_value("1.5")
      assert {:error, _} = S3.concurrency_setting()
    end

    test "trailing rubbish is refused rather than partially parsed" do
      with_value("8x")
      assert {:error, _} = S3.concurrency_setting()
    end

    # Refused, NOT clamped. Clamping would substitute a number the operator did
    # not ask for and label the run with a concurrency it did not use — the same
    # class of wrong answer as reading "one" as 16.
    test "above the ceiling is refused, and the error says so rather than clamping" do
      with_value("100000")
      assert {:error, message} = S3.concurrency_setting()
      assert message =~ "100000"
      assert message =~ "256"
      refute S3.concurrency_setting() == {:ok, 256}
    end

    # A reader whose value was refused should not have to find the accepted
    # range elsewhere.
    test "the error names what it will accept" do
      with_value("nope")
      assert {:error, message} = S3.concurrency_setting()
      assert message =~ "positive integer"
      assert message =~ "256"
    end

    test "concurrency/0 raises rather than falling back to the derivation" do
      with_value("one")

      assert_raise ArgumentError, fn -> S3.concurrency() end
    end
  end

  describe "the CLI reads it before any provider runs" do
    # `Depdep.CLI.disposition/1` calls `concurrency_setting/0` after `enabled?/0`
    # and turns an error into the same warn-and-halt path as an unknown switch,
    # so the refusal below is what stops the run. Asserted here rather than
    # through `main/1`, which halts the VM.
    test "the refusal names the variable, so a halted run says which one" do
      with_value("one")
      assert {:error, message} = S3.concurrency_setting()
      assert message =~ "DEPDEP_CONCURRENCY"
    end

    # An off switch that needs the rest of the environment to be right is no use
    # on the day it is not. A disabled run reads nothing else, so a typo here
    # must not stop the one invocation whose purpose is to do nothing.
    test "a disabled run is unaffected by a bad value" do
      with_value("one")
      original = System.get_env("DEPDEP_ENABLED")
      System.put_env("DEPDEP_ENABLED", "false")

      on_exit(fn ->
        if original,
          do: System.put_env("DEPDEP_ENABLED", original),
          else: System.delete_env("DEPDEP_ENABLED")
      end)

      assert CLI.enabled?() == {:ok, false}
    end
  end
end
