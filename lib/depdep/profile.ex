defmodule Depdep.Profile do
  @moduledoc """
  The depdep profile — `priv/profiles/depdep.exs` — and the check that keeps it
  honest against what `Depdep.Metresis` emits.

  No depdep profile ever existed. Nine metrics had been posting since v0.3.0 as
  auto-registered provisional gauges of `number`, with no unit, no polarity, no
  description and no dashboard, because metresis's profiles are shipped in its
  own `priv/profiles/` and nobody wrote one there. metresis #206 settled that
  the profile is the emitter's to ship (#69) — and, since #86, to carry on
  every post: `hash/0` is what `Depdep.Metresis` sends in `Metresis-Profile`,
  and the document is what it publishes when an instance answers 428. This
  module owns it.

  ## Two directions of drift, both caught

  A metric the code emits that the document does not name lands in metresis
  as a bare provisional again — the state this exists to end. A metric the
  document names that the code cannot emit is a definition nobody will ever
  fill, misleading the reader of the catalog. `check/0` diffs the document's
  vocabulary against `emitted/0` both ways, and `mix depdep.profile check` runs
  in CI so neither can land.

  `emitted/0` does not enumerate the code's vocabulary by hand — that would be
  a second copy free to drift. It runs `Depdep.Metresis.samples/1` over a
  synthetic run that exercises every branch, and reads the keys off the result.
  """

  alias Depdep.{Metresis, Metrics, Report}

  @doc """
  Where the document lives, for the task's messages.

  Resolved at runtime through the application's `priv/`, never fixed at
  compile time relative to this file: a path into the source tree is wrong the
  moment depdep is installed from a package, where `lib/` and `priv/` exist and
  the source tree does not (#73).
  """
  def path, do: Path.join(:code.priv_dir(:depdep), "profiles/depdep.exs")

  @doc """
  The document, evaluated. A literal map with string keys, exactly what
  `Depdep.Json.encode/1` turns into the request body.

  The file is depdep's own and versioned with it, which is what makes
  `Code.eval_file/1` acceptable here where metresis's loader refuses it for
  user-supplied profiles.
  """
  def read do
    {document, _bindings} = Code.eval_file(path())
    document
  end

  @doc "The metric keys and label keys the document declares."
  def vocabulary(document \\ read()) do
    %{
      metrics: document |> Map.fetch!("metrics") |> Enum.map(& &1["key"]) |> MapSet.new(),
      label_keys: document |> Map.fetch!("label_keys") |> Enum.map(& &1["key"]) |> MapSet.new(),
      bucket_values:
        document
        |> Map.fetch!("label_keys")
        |> Enum.find(&(&1["key"] == "bucket"))
        |> Kernel.||(%{})
        |> Map.get("expected_values", [])
        |> MapSet.new()
    }
  end

  @doc """
  The metric keys and label keys `Depdep.Metresis` can produce, read off a
  synthetic run that takes every branch: both directions, a unit in every
  bucket, a compiled miss, a hit that knows what it saved, a reason, and the
  run-level labels both in and out of CI.
  """
  def emitted do
    samples = Enum.flat_map([:pull, :push], &Metresis.samples(synthetic_run(&1)))

    run_labels =
      [Metresis.labels(:pull), %{"run" => "local"}]
      |> Enum.flat_map(&Map.keys/1)
      |> MapSet.new()

    %{
      metrics: samples |> Enum.map(& &1["metric"]) |> MapSet.new(),
      label_keys:
        samples
        |> Enum.flat_map(&Map.keys(&1["labels"] || %{}))
        |> MapSet.new()
        |> MapSet.union(run_labels)
        |> MapSet.union(ci_label_keys()),
      bucket_values:
        [:pull, :push]
        |> Enum.flat_map(&Keyword.keys(Report.buckets(&1)))
        |> Enum.map(&to_string/1)
        |> MapSet.new()
    }
  end

  # `Metresis.labels/1` omits what the environment lacks, so outside CI the
  # GitLab keys are absent from a real call. They are still part of what the
  # code can emit; naming them here is the one place a key is written down
  # rather than observed, and it is a copy of the map in `labels/1`.
  defp ci_label_keys,
    do: MapSet.new(~w(project commit ref pipeline job job_name direction run))

  defp synthetic_run(direction) do
    units =
      for {bucket, _label} <- Report.buckets(direction) do
        %Metrics.Unit{
          provider: "mix",
          label: "app/#{bucket}",
          bucket: bucket,
          reason: if(bucket in [:missing, :skipped], do: "not found"),
          download_us: 10,
          restore_us: 10,
          bytes: 10,
          compile_us: if(bucket == :missing, do: 1_000, else: nil),
          compile_exact: if(bucket == :missing, do: true, else: nil),
          saved_us: if(bucket in [:pulled, :present], do: 1_000, else: nil),
          compile_carried_us: if(bucket in [:pulled, :present], do: 2_000, else: nil)
        }
      end

    phase = %Metrics.Phase{
      provider: "mix",
      direction: direction,
      span_us: 100,
      concurrency: 8,
      tally: Map.new(units, &{&1.bucket, 1}),
      units: units
    }

    Metrics.to_map([phase], direction, 200)
  end

  @doc """
  `:ok`, or `{:error, problems}` naming every way the document and the code
  disagree. Each problem is one line a reader can act on.
  """
  def check(document \\ read()) do
    declared = vocabulary(document)
    actual = emitted()

    problems =
      missing(actual.metrics, declared.metrics, "emitted but not in the profile: metric") ++
        missing(declared.metrics, actual.metrics, "in the profile but never emitted: metric") ++
        missing(actual.label_keys, declared.label_keys, "emitted but not in the profile: label") ++
        missing(declared.label_keys, actual.label_keys, "in the profile but never emitted: label") ++
        missing(
          actual.bucket_values,
          declared.bucket_values,
          "bucket value not expected by the profile"
        ) ++
        missing(
          declared.bucket_values,
          actual.bucket_values,
          "profile expects a bucket value the code has not"
        )

    case problems do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  @doc """
  What this depdep ships against what an instance holds: a list of
  differences, empty when they agree.

  **Not a hash comparison.** A hash says "differs" without saying how, and the
  how is the whole value: on cn2 the four compile-timing metrics were present
  but catalogued as bare `number`s rather than durations in seconds, which a
  hash would have reported identically to a metric being absent (#100). So
  this compares the vocabulary — which metric keys each side has, and for the
  ones in common, the four fields that decide how a panel may draw them —
  and names each difference in the shape `check/1` uses.

  `theirs` is the document the instance returns, with string keys throughout;
  `:absent` when it holds no such profile at all, which is itself the finding.
  """
  def compare(mine, theirs, url)

  def compare(_mine, :absent, url), do: ["no depdep profile on #{url} at all"]

  def compare(mine, theirs, url) do
    mine_metrics = by_key(mine, "metrics")
    their_metrics = by_key(theirs, "metrics")

    version(mine, theirs, url) ++
      missing(
        MapSet.new(Map.keys(mine_metrics)),
        MapSet.new(Map.keys(their_metrics)),
        "in the profile but not on #{url}: metric"
      ) ++
      missing(
        MapSet.new(Map.keys(their_metrics)),
        MapSet.new(Map.keys(mine_metrics)),
        "on #{url} but not in the profile: metric"
      ) ++
      fields(mine_metrics, their_metrics, url) ++
      missing(
        MapSet.new(Map.keys(by_key(mine, "label_keys"))),
        MapSet.new(Map.keys(by_key(theirs, "label_keys"))),
        "in the profile but not on #{url}: label"
      )
  end

  # The four that decide whether a panel can draw two series on one axis, and
  # whether up is good. `nil` on either side is a real difference: a metric
  # registered provisionally has no unit at all.
  @compared ~w(type quantity unit polarity)

  # `their_metric = ...` is a filter on purpose — a metric the instance lacks
  # is reported by `missing/3` above, not here. Nothing ELSE may be written as
  # an assignment: in a comprehension an assignment is a filter on its own
  # value, so binding a field would drop exactly the case this exists for, a
  # metric catalogued with no unit at all.
  defp fields(mine, theirs, url) do
    for {key, mine_metric} <- Enum.sort(mine),
        their_metric = Map.get(theirs, key),
        field <- @compared,
        Map.get(mine_metric, field) != Map.get(their_metric, field) do
      "metric #{key}: #{field} #{inspect(Map.get(their_metric, field))} on #{url}, " <>
        "#{inspect(Map.get(mine_metric, field))} here"
    end
  end

  defp version(mine, theirs, url) do
    case {Map.get(mine, "version"), Map.get(theirs, "version")} do
      {same, same} -> []
      {mine_v, their_v} -> ["version #{inspect(their_v)} on #{url}, #{inspect(mine_v)} here"]
    end
  end

  defp by_key(document, key) do
    document
    |> Map.get(key, [])
    |> Map.new(fn entry -> {entry["key"], entry} end)
  end

  @doc """
  The SHA-256 of the document's canonical JSON — sorted keys, no whitespace,
  `Depdep.Json.encode/1`'s output — as lowercase hex. What every ingest post
  carries in `Metresis-Profile`, and what metresis compares with the hash it
  computed the same way over what it holds (metresis #243).
  """
  def hash(document \\ read()) do
    :crypto.hash(:sha256, Depdep.Json.encode(document)) |> Base.encode16(case: :lower)
  end

  defp missing(from, in_set, what) do
    from
    |> MapSet.difference(in_set)
    |> Enum.sort()
    |> Enum.map(&"#{what} #{&1}")
  end
end
