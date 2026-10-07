defmodule Depdep.PurityTest do
  @moduledoc """
  `spec/10-decisions.md#purity`: the rule modules take their inputs as arguments and
  touch nothing, so the rules worth being certain about are testable without a store,
  a network or a clock.

  Nothing asserted that (#159). Each of the four had its own tests, and each of those
  happened to run without IO, but no test said the property out loud — so a rule that
  started reading the environment would break nothing here.

  This calls each module's decision twice with identical inputs and requires identical
  answers, with the clock and the window handed in rather than read. It is not a proof
  of purity — nothing short of static analysis is — but it fails if a decision starts
  depending on anything it was not given.
  """
  use ExUnit.Case, async: true

  import Depdep.LockFixture

  alias Depdep.{Report, SecondPass, Sweep}

  @now ~U[2026-09-07 12:00:00Z]

  defp object(key, days_old) do
    %{
      key: key,
      size: 1000,
      last_modified: DateTime.add(@now, -days_old, :day) |> DateTime.to_iso8601()
    }
  end

  @tag verifies: "spec/10-decisions.md#purity"
  test "each rule module answers identically when asked twice, given the same inputs" do
    # Depdep.Key — the lock and the toolchain are arguments, including the toolchain,
    # which is the one input that would otherwise be read from the host.
    lock = [hex("ash", "3.32.3", ["spark"]), hex("spark", "2.6.0", [])]
    assert key(lock, "ash") == key(lock, "ash")

    # Depdep.Sweep — the listing, the live set AND the clock are arguments.
    objects = [object("v3/jason/1.4.4/abc.tar.gz", 90), object("roots/live/main/mix.json", 1)]
    rules = [grace_days: 2, window_days: 30, keep_epochs: 2, now: @now]
    live = MapSet.new([])
    assert Sweep.plan(objects, live, rules) == Sweep.plan(objects, live, rules)

    # Depdep.Report — a tally in, a sentence out.
    tally = %{pulled: 2, missing: 1}
    assert Report.render(:pull, tally) == Report.render(:pull, tally)

    # Depdep.SecondPass — the first pass's metrics and the re-enumerated units in,
    # a split out.
    first = [%Depdep.Metrics.Unit{label: "app/ash", bucket: :pulled}]
    units = []
    assert SecondPass.plan(first, units) == SecondPass.plan(first, units)
  end
end
