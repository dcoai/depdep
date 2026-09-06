defmodule Depdep.ReportTest do
  use ExUnit.Case, async: true

  alias Depdep.Report

  @keyed {:key, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
  @unkeyable {:skip, "git dependency — the lock carries no dependency list"}

  describe "outcome/3 — the three events that used to share one bucket" do
    test "a dependency that cannot be keyed is skipped, in either direction" do
      assert Report.outcome(:pull, @unkeyable, false) == {:done, :skipped}
      assert Report.outcome(:push, @unkeyable, false) == {:done, :skipped}
    end

    test "a keyed dependency already on disk is NOT a skip on pull" do
      assert Report.outcome(:pull, @keyed, true) == {:done, :present}
    end

    test "a keyed dependency not built here is NOT a skip on push" do
      assert Report.outcome(:push, @keyed, false) == {:done, :not_built}
    end

    test "only a keyed dependency reaches the store" do
      assert Report.outcome(:pull, @keyed, false) == {:network, :fetch}
      assert Report.outcome(:push, @keyed, true) == {:network, :offer}
    end
  end

  describe "count/3" do
    test "counts into the named bucket" do
      tally = %{} |> Report.count(:pull, :pulled) |> Report.count(:pull, :pulled)
      assert tally == %{pulled: 2}
    end

    # A bucket counted for the wrong direction would never be printed, which is
    # exactly the silent miscount this module exists to end.
    test "raises on a bucket that does not belong to the direction" do
      assert_raise ArgumentError, fn -> Report.count(%{}, :pull, :uploaded) end
      assert_raise ArgumentError, fn -> Report.count(%{}, :push, :missing) end
    end
  end

  describe "render/2" do
    test "pull names every bucket, in order, including the zeros" do
      tally = %{pulled: 555, missing: 8, present: 0, skipped: 1}

      assert Report.render(:pull, tally) ==
               "pulled 555, missing 8, already present 0, skipped 1"
    end

    test "push names every bucket, in order, including the zeros" do
      tally = %{stored: 555, uploaded: 0, not_built: 9, skipped: 0}

      assert Report.render(:push, tally) ==
               "already stored 555, uploaded 0, not built here 9, skipped 0"
    end

    test "an empty tally renders as zeros rather than omitting buckets" do
      assert Report.render(:pull, %{}) == "pulled 0, missing 0, already present 0, skipped 0"
    end
  end

  describe "merge/1" do
    test "sums the per-project tallies of one run" do
      merged = Report.merge([%{pulled: 3, skipped: 1}, %{pulled: 4}, %{missing: 2}])
      assert merged == %{pulled: 7, missing: 2, skipped: 1}
    end
  end

  # The property that makes the report trustworthy: every dependency considered
  # lands in exactly one bucket, so a number can be read as a count of packages.
  describe "the tally accounts for every dependency" do
    test "pull over a mixed set" do
      resolutions = [@keyed, @keyed, @unkeyable, @keyed]
      tally = tally(:pull, resolutions, complete?: true)

      assert Report.total(tally) == length(resolutions)
      assert tally == %{present: 3, skipped: 1}
    end

    test "push over a mixed set" do
      resolutions = [@keyed, @unkeyable, @keyed]
      tally = tally(:push, resolutions, complete?: false)

      assert Report.total(tally) == length(resolutions)
      assert tally == %{not_built: 2, skipped: 1}
    end

    # The property `ordered: false` on the transfer stream rests on: results
    # arrive in completion order, not lock order, and the tally must not care.
    test "the tally does not depend on the order outcomes arrive in" do
      resolutions = [@keyed, @unkeyable, @keyed, @unkeyable, @keyed]
      reference = tally(:pull, resolutions, complete?: true)

      for _ <- 1..20 do
        assert tally(:pull, Enum.shuffle(resolutions), complete?: true) == reference
      end
    end

    # The regression this work item exists for: before the split, this run
    # reported `skipped 555` and the README explained that number as a git
    # dependency, which it was not.
    test "a fully populated tree pulls with nothing skipped" do
      tally = tally(:pull, List.duplicate(@keyed, 555), complete?: true)

      assert Report.render(:pull, tally) ==
               "pulled 0, missing 0, already present 555, skipped 0"
    end
  end

  # Mirrors what `Depdep.CLI` does with a `{:done, _}` outcome. Fixtures are
  # chosen so nothing reaches the store, since only the store can resolve a
  # `{:network, _}`.
  defp tally(direction, resolutions, complete?: complete?) do
    Enum.reduce(resolutions, %{}, fn resolution, tally ->
      {:done, bucket} = Report.outcome(direction, resolution, complete?)
      Report.count(tally, direction, bucket)
    end)
  end
end
