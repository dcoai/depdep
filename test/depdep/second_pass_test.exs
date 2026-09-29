defmodule Depdep.SecondPassTest do
  use ExUnit.Case, async: true

  alias Depdep.{Metrics, SecondPass, Unit}

  defp unit(name, resolution),
    do: %Unit{group: "app", name: name, resolution: resolution, object: nil, detail: "-"}

  defp seen(name, bucket, extra \\ []),
    do: struct(%Metrics.Unit{provider: "mix", label: "app/#{name}", bucket: bucket}, extra)

  @keyed {:key, "abc"}
  @unkeyable {:skip, "git dependency — the lock carries no dependency list"}

  describe "plan/2" do
    @tag verifies: "second-pass-one-entry"
    test "a unit the first pass skipped is transferred, whatever it resolves to now" do
      first = [seen("forked", :skipped), seen("dependent", :skipped)]
      units = [unit("forked", @keyed), unit("dependent", @unkeyable)]

      {transfer, settled} = SecondPass.plan(first, units)
      assert Enum.map(transfer, & &1.name) == ["forked", "dependent"]
      assert settled == []
    end

    # The request was made and answered "not found", correctly — because
    # nothing will ever build it here. No second request is needed to say so.
    test "a first-pass miss the graph now proves outside the env is re-bucketed on paper" do
      first = [seen("ex_doc", :missing, reason: "not found", download_us: 12)]
      units = [unit("ex_doc", {:not_for_env, :test})]

      assert {[], [settled]} = SecondPass.plan(first, units)
      assert settled.bucket == :not_for_env
      assert settled.reason == nil
      assert settled.download_us == 12, "the cost of the request stays on the record"
    end

    test "everything else keeps its first-pass outcome untouched" do
      first = [seen("jason", :pulled, download_us: 300), seen("decimal", :missing)]
      units = [unit("jason", @keyed), unit("decimal", @keyed)]

      assert {[], settled} = SecondPass.plan(first, units)
      assert settled == first
    end

    # Outside CI `deps.get` may add a lock entry; nothing has decided it yet.
    test "a unit the first pass never saw is transferred" do
      assert {[%Unit{name: "new"}], []} = SecondPass.plan([], [unit("new", @keyed)])
    end
  end

  describe "merge/4" do
    test "one entry per unit, the tally recounted, the span extended" do
      phase = %Metrics.Phase{
        provider: "mix",
        direction: :pull,
        span_us: 1_000,
        concurrency: 8,
        tally: %{skipped: 2, missing: 1},
        units: [seen("forked", :skipped), seen("dependent", :skipped), seen("ex_doc", :missing)]
      }

      settled = [seen("ex_doc", :not_for_env)]
      transferred = [seen("forked", :pulled), seen("dependent", :pulled)]

      merged = SecondPass.merge(phase, settled, transferred, 500)

      assert merged.tally == %{pulled: 2, not_for_env: 1}
      assert length(merged.units) == 3
      assert merged.span_us == 1_500
      assert Depdep.Report.total(merged.tally) == length(phase.units)
    end
  end
end
