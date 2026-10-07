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

  @doc """
  The SHA-256 of the document **without** `"version"`, as lowercase hex.

  What `mix depdep.profile golden` holds the version against (#171, for #111). `hash/0`
  cannot do this job: it covers the whole document, `"version"` included, because that is
  what the wire handshake compares — so bumping the version changes it, and "bumped and
  nothing else" would be indistinguishable from "changed and bumped".

  Excluding the one field being guarded makes both directions exact: content moved with the
  version standing still is a document that announces nothing, and a version that moved with
  the content standing still is a bump that means nothing.
  """
  def content_hash(document \\ read()) do
    document
    |> Map.delete("version")
    |> Depdep.Json.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The whole published vocabulary, in the order the golden prints it.

  Everything a reader of `PROFILE.md` needs to see change: each metric with its unit and
  polarity, the label keys, the `bucket` values, and the dashboard's panel titles. Wider
  than `vocabulary/1`, which answers the narrower question of what the code must emit.
  """
  def published(document \\ read()) do
    %{
      version: Map.fetch!(document, "version"),
      content_hash: content_hash(document),
      metrics:
        document
        |> Map.fetch!("metrics")
        |> Enum.map(&{&1["key"], &1["unit"], &1["polarity"]})
        |> Enum.sort(),
      label_keys: document |> Map.fetch!("label_keys") |> Enum.map(& &1["key"]) |> Enum.sort(),
      bucket_values: vocabulary(document).bucket_values |> Enum.sort(),
      # Panels are nested under each dashboard's `layout`, not directly under it — read
      # off the file rather than guessed, because a wrong path here would silently
      # publish an empty panel list and the golden would record that as correct.
      panels:
        document
        |> Map.get("dashboards", [])
        |> Enum.flat_map(&(get_in(&1, ["layout", "panels"]) || []))
        |> Enum.map(& &1["title"])
        |> Enum.sort()
    }
  end

  @golden_path "PROFILE.md"

  @doc "Where the golden lives, relative to the project root."
  def golden_path, do: @golden_path

  @doc """
  The golden's text: what depdep publishes, and the version that announces it.

  A pure function of the document, so writing it and checking it cannot disagree.
  """
  def golden(document \\ read()) do
    p = published(document)

    """
    # PROFILE.md
    What depdep publishes to metresis, and the version that announces it.
    Generated by `mix depdep.profile golden --write` · checked by `mix depdep.profile check`
    (HARD, in the `test` job) — do not edit; a drift FAILS the check.

    **The version and the content are bound.** Change anything in
    `priv/profiles/depdep.exs` and the content hash moves, so `"version"` must move too;
    bump the version without changing anything and the check fails as well, because a bump
    that announces nothing is worse than no bump (#111). metresis takes the version verbatim
    and its loader states the contract: a version bump is how an update announces itself.

    The content hash excludes `"version"` itself. `Depdep.Profile.hash/0` — the one every
    ingest post carries — includes it, because the instance compares the whole document.

    **version #{p.version}** · content hash `#{p.content_hash}`

    ## metrics (#{length(p.metrics)})

    | key | unit | polarity |
    |---|---|---|
    #{Enum.map_join(p.metrics, "\n", fn {k, u, pol} -> "| `#{k}` | #{u} | #{pol} |" end)}

    ## label keys (#{length(p.label_keys)})

    #{Enum.map_join(p.label_keys, ", ", &"`#{&1}`")}

    ## bucket values (#{length(p.bucket_values)})

    #{Enum.map_join(p.bucket_values, ", ", &"`#{&1}`")}

    ## dashboard panels (#{length(p.panels)})

    #{Enum.map_join(p.panels, "\n", &"- #{&1}")}
    """
  end

  @doc """
  Whether the golden on disk matches the document: `:ok` or `{:drift, lines}`.

  The lines name **what** changed, not merely that something did — the version against the
  content, then each metric, label, bucket value and panel that appeared or went. A check
  that says only "the golden is stale" makes a reader diff it by hand.
  """
  def golden_check(document \\ read()) do
    case File.read(Path.join(File.cwd!(), @golden_path)) do
      {:ok, on_disk} -> compare_golden(on_disk, document)
      {:error, reason} -> {:drift, ["#{@golden_path} is unreadable (#{reason})"]}
    end
  end

  defp compare_golden(on_disk, document) do
    fresh = golden(document)

    if on_disk == fresh do
      :ok
    else
      {:drift, golden_differences(on_disk, document) ++ [regenerate_hint(on_disk, document)]}
    end
  end

  # The version/content question first, because it is the one the guard exists for and the
  # one whose answer decides what the author has to do.
  defp golden_differences(on_disk, document) do
    p = published(document)
    was_version = captured(on_disk, ~r/\*\*version (\d+)\*\*/)
    was_content = captured(on_disk, ~r/content hash `([0-9a-f]+)`/)

    cond do
      was_content != nil and was_content != p.content_hash and was_version == "#{p.version}" ->
        [
          "the profile changed but \"version\" is still #{p.version} — a change nothing" <>
            " announces is a change metresis cannot offer"
        ] ++ vocabulary_differences(on_disk, p)

      was_content != nil and was_content == p.content_hash and was_version != "#{p.version}" ->
        [
          "\"version\" moved to #{p.version} but the profile is unchanged — a bump that" <>
            " announces nothing"
        ]

      true ->
        vocabulary_differences(on_disk, p)
    end
  end

  # Both directions, per section. A removed metric matters as much as an added one — it is a
  # metric some dashboard may still query — so the golden is parsed back rather than merely
  # searched for the new names.
  defp vocabulary_differences(on_disk, p) do
    Enum.flat_map(
      [
        {"metric", Enum.map(p.metrics, &elem(&1, 0)), backticked(on_disk, "metrics")},
        {"label key", p.label_keys, backticked(on_disk, "label keys")},
        {"bucket value", p.bucket_values, backticked(on_disk, "bucket values")},
        {"panel", p.panels, bulleted(on_disk, "dashboard panels")}
      ],
      fn {what, fresh, was} ->
        Enum.map(fresh -- was, &"#{what} added: #{&1}") ++
          Enum.map(was -- fresh, &"#{what} gone: #{&1}")
      end
    )
  end

  # Everything in backticks under a `## <heading>` section, up to the next heading. Covers
  # both shapes the golden uses: a table's first column and an inline comma-separated list.
  defp backticked(text, heading) do
    ~r/`([^`]+)`/
    |> Regex.scan(section(text, heading))
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.sort()
  end

  defp bulleted(text, heading) do
    text
    |> section(heading)
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(&String.trim_leading(&1, "- "))
    |> Enum.sort()
  end

  # `## <heading>` is matched with its own count in parentheses, which the golden always
  # writes, so `## metrics (14)` is found by "metrics" alone.
  defp section(text, heading) do
    case String.split(text, ~r/^## #{Regex.escape(heading)} \(\d+\)$/m, parts: 2) do
      [_before, after_heading] -> after_heading |> String.split(~r/^## /m, parts: 2) |> hd()
      _ -> ""
    end
  end

  defp regenerate_hint(_on_disk, _document),
    do: "run `mix depdep.profile golden --write` once the version is right"

  defp captured(text, regex) do
    case Regex.run(regex, text) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp missing(from, in_set, what) do
    from
    |> MapSet.difference(in_set)
    |> Enum.sort()
    |> Enum.map(&"#{what} #{&1}")
  end
end
