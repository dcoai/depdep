defmodule Depdep.MetricsTest do
  @moduledoc """
  The rollups, which are arithmetic over recorded numbers and need no network —
  the same reason `Depdep.Report` and `Depdep.Sweep` are testable this way.
  """
  use ExUnit.Case, async: true

  alias Depdep.Metrics
  alias Depdep.Metrics.{Phase, Unit}

  defp unit(opts \\ []) do
    struct(
      %Unit{provider: "mix", label: "jason", bucket: :pulled},
      opts
    )
  end

  defp phase(units, opts \\ []) do
    struct(
      %Phase{provider: "mix", direction: :pull, span_us: 1_000, concurrency: 8, units: units},
      opts
    )
  end

  describe "a unit's cost is two numbers, not one" do
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "download and extract are kept apart and summed on request" do
      u = unit(download_us: 400, restore_us: 180)
      assert Metrics.unit_us(u) == 580
      assert u.download_us == 400
      assert u.restore_us == 180
    end

    # The question anyone asks first is "network or tar?", and a single total
    # cannot answer it.
    test "a download with no extract is distinguishable from a fast extract" do
      slow_network = unit(download_us: 900, restore_us: 0)
      slow_tar = unit(download_us: 0, restore_us: 900)

      assert Metrics.unit_us(slow_network) == Metrics.unit_us(slow_tar)
      refute slow_network.download_us == slow_tar.download_us
    end
  end

  describe "span and sum are different measurements, and both are wanted" do
    # Units run 8-32 at a time, so summed unit time normally EXCEEDS the span
    # that contains them. This is the measurement, not a bug to reconcile — and
    # this test exists so neither is later "corrected" into the other.
    # The section's claim that sum_unit_us/1 says where the time went (#194).
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "the sum may exceed the span, and that is not an error" do
      p = phase([unit(download_us: 800), unit(download_us: 800)], span_us: 1_000)

      assert Metrics.sum_unit_us(p) == 1_600
      assert p.span_us == 1_000
      assert Metrics.sum_unit_us(p) > p.span_us
    end

    # The section's claim: how much of the configured concurrency was used (#194).
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "effective parallelism is the ratio of the two" do
      p = phase([unit(download_us: 1_000), unit(download_us: 1_000)], span_us: 1_000)
      assert Metrics.effective_parallelism(p) == 2.0
    end

    # Ten units averaging 2s inside a 3s span is ~6.7 — and if the concurrency
    # in force was 32, the limit was not what bound the run.
    test "the ratio is readable against the concurrency in force" do
      units = for _ <- 1..10, do: unit(download_us: 2_000_000)
      p = phase(units, span_us: 3_000_000, concurrency: 32)

      assert Metrics.effective_parallelism(p) == 6.67
      assert p.concurrency == 32
    end

    # A phase that did no work, not infinite parallelism.
    test "a zero span has no ratio rather than a division by zero" do
      assert Metrics.effective_parallelism(phase([], span_us: 0)) == nil
      assert Metrics.effective_parallelism(phase([], span_us: nil)) == nil
    end
  end

  describe "what the store saved, which is nil when nothing knew" do
    # Added in #194. The section names `saved_total_us/1` as the figure for what the
    # store saved, and NOTHING called it directly — it was reached only through
    # `to_map/4`, so its own contract (summing across phases, and absence rather than
    # zero) was never asserted. Found by re-validating the relation the section's
    # citation manufactured, which is the #160 pathology seen from the other side: a
    # cited item with no verifier is a claim nobody checks.
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "it sums what every phase saved, across providers" do
      mix = phase([unit(saved_us: 1_000), unit(saved_us: 500)])
      apt = phase([unit(saved_us: 250)])

      assert Metrics.saved_total_us([mix, apt]) == 1_750
    end

    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "a run where no hit knew its compile time has no total, rather than zero" do
      # Zero would drag an average toward it and read as 'the store saved nothing',
      # which is a different claim from 'nothing measured it'.
      assert Metrics.saved_total_us([phase([unit()])]) == nil
    end

    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "one hit that knew is enough for a total, and the unknowing are not counted as zero" do
      assert Metrics.saved_total_us([phase([unit(saved_us: 300), unit()])]) == 300
    end
  end

  describe "stragglers and bytes" do
    # One large object finishing long after 147 others is invisible in an
    # aggregate and obvious here.
    # The section's claim that the outliers worth looking at are named (#194).
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "the slowest unit is named, not just its duration" do
      units = [unit(label: "small", download_us: 10), unit(label: "huge", download_us: 9_000)]
      assert Metrics.slowest(phase(units)).label == "huge"
    end

    test "an empty phase has no slowest unit" do
      assert Metrics.slowest(phase([])) == nil
    end

    # The section's claim that bytes/1 is the volume figure (#194).
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "bytes are summed across the phase" do
      assert Metrics.bytes(phase([unit(bytes: 100), unit(bytes: 20)])) == 120
    end
  end

  describe "to_map is the wire shape" do
    setup do
      p =
        phase([unit(download_us: 400, restore_us: 100, bytes: 2_048, offset_us: 5)],
          span_us: 500
        )

      %{map: Metrics.to_map([p], :pull, 900)}
    end

    test "the run carries the direction and its own elapsed time", %{map: map} do
      assert map.direction == :pull
      assert map.elapsed_us == 900
    end

    # Tagged in #194. The section cited ten code items against ONE verifier, so adding
    # a paragraph to it dangled eight `implements` relations that nothing could
    # re-validate — the narration-density pathology #160 measures. This test checks the
    # section's per-run-and-per-provider claim: the rollups are carried, so a reader
    # does not recompute them.
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "a phase carries the rollups, so a reader does not recompute them", %{map: map} do
      [phase] = map.phases

      assert phase.provider == "mix"
      assert phase.span_us == 500
      assert phase.concurrency == 8
      assert phase.sum_unit_us == 500
      assert phase.effective_parallelism == 1.0
      assert phase.bytes == 2_048
    end

    test "units survive as plain maps, with both halves intact", %{map: map} do
      [%{units: [u]}] = map.phases

      assert u.download_us == 400
      assert u.restore_us == 100
      assert u.bytes == 2_048
      assert u.offset_us == 5
      assert u.bucket == :pulled
    end

    # `Report.duration/1` rounds to 0.1s, which is right for a line someone
    # reads and useless for a series.
    test "times are microseconds, unrounded", %{map: map} do
      [%{units: [u]}] = map.phases
      assert is_integer(u.download_us)
      assert map.elapsed_us == 900
    end

    test "it round-trips through the encoder", %{map: map} do
      json = Depdep.Json.encode(map)

      assert json =~ ~s("direction":"pull")
      assert json =~ ~s("effective_parallelism":1.0)
      assert json =~ ~s("bucket":"pulled")
    end
  end

  describe "the bootstrap, which depdep cannot cache because it precedes the cache" do
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "bootstrap_us/0 reports the VM's own clock, in microseconds" do
      # `Mix.install/2` runs inside the already-started VM, so wall-clock-since-VM-start
      # read at depdep's first line IS the bootstrap. Measured in #191: 2402 ms against
      # a 2490 ms process total, the gap being VM start and exit.
      #
      # This asserts the CONTRACT, not a duration — a test that pinned seconds would be
      # asserting the speed of whatever machine ran it. What must hold is the unit and
      # the direction of travel.
      first = Metrics.bootstrap_us()

      assert is_integer(first)
      assert first > 0

      # **Microseconds, not the milliseconds the VM hands out — checked by scale, not
      # by magnitude.** The first version of this asserted `first >= 1_000` and claimed
      # to catch a dropped conversion. It does not: by the time the suite reaches this
      # line the VM has been up for seconds, so the raw millisecond figure clears 1_000
      # too. Proven by dropping the `* 1_000` and watching this test stay green.
      #
      # A sleep gives an independently known interval, so the UNIT is what is under
      # test: 50 ms must read as ~50_000, and a figure near 50 means milliseconds
      # leaked through. Also the monotonicity check — `:wall_clock` counts from VM
      # start rather than from the system clock, so an NTP step cannot move it.
      Process.sleep(50)
      elapsed = Metrics.bootstrap_us() - first

      assert elapsed >= 40_000,
             "#{elapsed} over a 50 ms sleep is milliseconds, not microseconds"
    end

    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "to_map carries it, and a caller that did not read the clock says nothing" do
      p = phase([unit()], span_us: 500)

      assert Metrics.to_map([p], :pull, 900, 1_500_000).bootstrap_us == 1_500_000

      # `nil` rather than 0 for a caller that could not read it. Zero would be a claim
      # that the bootstrap was free, which is the opposite of what #191 measured, and
      # `Depdep.Metresis` drops the sample instead of posting that claim.
      assert Metrics.to_map([p], :pull, 900).bootstrap_us == nil
    end
  end

  describe "write/2" do
    # The section's closing claim: the measurements are recorded for a later push
    # to find (#194).
    @tag verifies: "spec/07-metrics-and-profile.md#metrics"
    test "writes JSON that the encoder produced" do
      path =
        Path.join(System.tmp_dir!(), "depdep-metrics-#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)

      assert Metrics.write(path, Metrics.to_map([phase([unit()])], :pull, 10)) == :ok
      assert File.read!(path) =~ ~s("direction":"pull")
    end

    # A measurement that could break a pipeline would be a worse instrument than
    # no measurement, so this returns rather than raising and the caller warns.
    test "an unwritable path is an error to report, not an exception" do
      path =
        Path.join(System.tmp_dir!(), "no-such-dir-#{System.unique_integer([:positive])}/m.json")

      assert {:error, message} = Metrics.write(path, %{})
      assert message =~ path
    end
  end

  describe "the per-provider structure survives" do
    # `Report.merge/1` was flattening mix, apt and git one line before printing,
    # so a run that spent 1.3s in apt and 4.2s in mix reported one number.
    test "two providers keep separate spans and tallies" do
      mix = phase([unit()], provider: "mix", span_us: 4_200, tally: %{pulled: 48})
      apt = phase([unit()], provider: "apt", span_us: 1_300, tally: %{pulled: 44})

      map = Metrics.to_map([mix, apt], :pull, 5_500)
      assert Enum.map(map.phases, & &1.provider) == ["mix", "apt"]
      assert Enum.map(map.phases, & &1.span_us) == [4_200, 1_300]
    end

    # The summary line is still the merge of the per-provider tallies, and must
    # read exactly as it did before the tallies moved onto the phases.
    test "merging the phases' tallies reproduces today's summary line" do
      mix = phase([], tally: %{pulled: 48, missing: 1, skipped: 3})
      apt = phase([], tally: %{pulled: 44})

      merged = Depdep.Report.merge(Enum.map([mix, apt], & &1.tally))

      assert Depdep.Report.render(:pull, merged) ==
               "pulled 92, missing 1, already present 0, skipped 3, not for this env 0"
    end
  end
end
