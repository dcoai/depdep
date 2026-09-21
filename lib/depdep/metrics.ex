defmodule Depdep.Metrics do
  @moduledoc """
  What a transfer cost, in enough detail to answer a question about it.

  Depdep already timed itself — one `:timer.tc` around the whole run — and threw
  the rest away. That line cannot say whether a slow pull was the network or the
  tar, which provider dominated, or which unit was the straggler, and a single
  sample of it cannot answer a timing question at all: consumer job durations
  vary 3.3–3.5x on identical code (`compile` 74.9–252.8 s on `dco-tek/metresis`
  `main`) against a depdep cost of 1.3–4.2 s. #41 records the same pathology on
  `dco-tek/bizex`, where a real-looking "254 s to 165 s" would have been
  variance. **The instrument has to be a series, so the run has to emit data.**

  Pure, like `Depdep.Report` and `Depdep.Sweep`: everything here is arithmetic
  over recorded numbers, so it tests without a network.

  ## Span is not the sum, and both are wanted

  Units run 8–32 at a time (`Depdep.S3.concurrency/0`), so the summed per-unit
  time normally EXCEEDS the wall-clock span of the phase that contains them.
  That is not a bug to be reconciled — it is the measurement:

    * `span_us` — how long the concurrent phase actually took.
    * `sum_unit_us/1` — how much work happened inside it.
    * `effective_parallelism/1` — the ratio, and the thing worth reading.

  Compared against `concurrency`, the ratio says whether the limit was the
  constraint. Ten units averaging 2 s inside a 3 s span is a parallelism of
  ~6.7; if the concurrency in force was 32, the limit was not what bound the
  run and raising it would do nothing.

  **It is an upper bound on the speedup over serial**, not the speedup itself:
  concurrent units contend for CPU during extraction and for bandwidth, so each
  measured time is inflated relative to running it alone. Honest, and far
  tighter than the synthetic benchmark #41 is open about.
  """

  defmodule Unit do
    @moduledoc """
    One unit's cost.

    `download_us` and `restore_us` are separate because `Depdep.CLI` calls
    `Depdep.S3.get/3` and `provider.restore/2` on adjacent lines, and merging
    them loses the only question anyone asks first: network, or tar?

    `offset_us` is entry time relative to the start of the phase, so queue wait
    is visible. Without it, a run where the concurrency limit was binding looks
    exactly like one where it was not.

    `compile_us` is set only on a miss that `--compile-deps` compiled — the one
    moment the number exists — and `compile_exact` says whether Mix's own
    boundaries measured it (`true`) or rebar3's start and the next boundary did
    (`false`). `nil` on every other unit: absent is not zero (#59).

    `saved_us` is set on a hit whose object carried a compile time: that time,
    less what the transfer cost, floored at zero. `nil` for a hit on an object
    stored before compile times were, and for everything that is not a hit.
    """
    defstruct [
      :provider,
      :label,
      :bucket,
      :reason,
      :compile_us,
      :compile_exact,
      :saved_us,
      rebuilt: false,
      offset_us: 0,
      download_us: 0,
      restore_us: 0,
      bytes: 0
    ]
  end

  defmodule Phase do
    @moduledoc """
    One provider's concurrent phase.

    Per provider rather than per run because providers run sequentially — a
    plain `Enum.map` — while units inside one run concurrently. A merged figure
    cannot show that apt took 1.3 s and mix 4.2 s, and `Depdep.Report.merge/1`
    was discarding exactly that one line before it was printed.
    """
    defstruct [:provider, :direction, :span_us, :concurrency, tally: %{}, units: []]
  end

  @doc "Download plus extract, for one unit."
  def unit_us(%Unit{download_us: d, restore_us: r}), do: d + r

  @doc "How much work happened inside the phase — normally MORE than its span."
  def sum_unit_us(%Phase{units: units}), do: units |> Enum.map(&unit_us/1) |> Enum.sum()

  @doc "Bytes moved in the phase."
  def bytes(%Phase{units: units}), do: units |> Enum.map(& &1.bytes) |> Enum.sum()

  @doc """
  Time the run's hits saved, summed over the units that know — or `nil` when
  none does, which is "no information" rather than "nothing saved".
  """
  def saved_total_us(phases) do
    case for %Phase{units: units} <- phases, %Unit{saved_us: us} <- units, us != nil, do: us do
      [] -> nil
      known -> Enum.sum(known)
    end
  end

  @doc """
  `sum_unit_us / span_us`, rounded — how many units were genuinely in flight.

  `nil` when the span is zero, which is a phase that did no work rather than
  infinite parallelism.
  """
  def effective_parallelism(%Phase{span_us: span}) when span in [0, nil], do: nil

  def effective_parallelism(%Phase{span_us: span} = phase),
    do: Float.round(sum_unit_us(phase) / span, 2)

  @doc """
  The slowest unit, or `nil` for a phase with none.

  Compared against the span it names a straggler: one large object finishing
  long after 147 others is invisible in an aggregate and obvious here.
  """
  def slowest(%Phase{units: []}), do: nil
  def slowest(%Phase{units: units}), do: Enum.max_by(units, &unit_us/1)

  @doc """
  The whole run as plain maps, ready for `Depdep.Json` or a metresis post.

  Microseconds throughout, unrounded. `Depdep.Report.duration/1` rounds to
  0.1 s, which is right for a line someone reads and useless for a series.
  """
  def to_map(phases, direction, elapsed_us) do
    %{
      direction: direction,
      elapsed_us: elapsed_us,
      saved_total_us: saved_total_us(phases),
      rebuilt_after_restore: Depdep.RestoreCheck.count(phases),
      phases: Enum.map(phases, &phase_map/1)
    }
  end

  @doc """
  Writes the run to `path` as JSON: `:ok`, or `{:error, message}`.

  Returns rather than raises, and the caller warns. A measurement that could
  break a pipeline would be a worse instrument than no measurement — `--metrics`
  is a debugging convenience, not the record.
  """
  def write(path, map) do
    case File.write(path, Depdep.Json.encode(map)) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp phase_map(%Phase{} = phase) do
    %{
      provider: phase.provider,
      span_us: phase.span_us,
      concurrency: phase.concurrency,
      sum_unit_us: sum_unit_us(phase),
      effective_parallelism: effective_parallelism(phase),
      bytes: bytes(phase),
      tally: phase.tally,
      units: Enum.map(phase.units, &Map.from_struct/1)
    }
  end
end
