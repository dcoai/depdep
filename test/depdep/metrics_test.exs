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
    test "the sum may exceed the span, and that is not an error" do
      p = phase([unit(download_us: 800), unit(download_us: 800)], span_us: 1_000)

      assert Metrics.sum_unit_us(p) == 1_600
      assert p.span_us == 1_000
      assert Metrics.sum_unit_us(p) > p.span_us
    end

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

  describe "stragglers and bytes" do
    # One large object finishing long after 147 others is invisible in an
    # aggregate and obvious here.
    test "the slowest unit is named, not just its duration" do
      units = [unit(label: "small", download_us: 10), unit(label: "huge", download_us: 9_000)]
      assert Metrics.slowest(phase(units)).label == "huge"
    end

    test "an empty phase has no slowest unit" do
      assert Metrics.slowest(phase([])) == nil
    end

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

  describe "write/2" do
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
