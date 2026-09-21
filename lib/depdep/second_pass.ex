defmodule Depdep.SecondPass do
  @moduledoc """
  What a pull does again once `mix deps.get` has run.

  The first pass runs before any source is on disk, and two things are
  undecidable then. A git dependency cannot be keyed — its lock entry carries
  no child list and Mix has not read its `mix.exs` — so it and its dependents
  are `skipped`. And Mix's list of what this env builds is incomplete, so
  nothing is called inactive: every lock entry is requested, which can only
  end in `missing` for one that was outside the env all along.

  With the source fetched, Mix's list is complete (`Depdep.Deps`) and both
  questions have exact answers. This module decides, unit by unit, whether the
  second enumeration changes anything: a unit the first pass skipped is
  transferred now; a first-pass miss the second pass proves outside the env is
  re-bucketed without a request; everything else keeps its first-pass outcome.
  One entry per unit survives, which is what keeps the summary line and the
  metrics honest — a unit is counted once, in the bucket the run ended with.

  Pure, so it tests without a store; `Depdep.CLI` runs the transfers it asks
  for.
  """

  alias Depdep.{Metrics, Report, Unit}

  @doc """
  `{transfer, settled}`: the units the second pass must transfer, and the
  first-pass metrics that stand as they are or are re-bucketed on paper.

  `first` is the first pass's `Metrics.Unit` list; `units` the re-enumerated
  `Depdep.Unit`s. A unit the first pass never saw — `deps.get` can add a lock
  entry outside CI — is transferred, since nothing decided it yet.
  """
  def plan(first, units) do
    seen = Map.new(first, &{&1.label, &1})

    Enum.reduce(units, {[], []}, fn unit, {transfer, settled} ->
      case {Map.get(seen, Unit.label(unit)), unit.resolution} do
        {nil, _} -> {[unit | transfer], settled}
        {%{bucket: :skipped}, _} -> {[unit | transfer], settled}
        {%{bucket: :missing} = m, {:not_for_env, _}} -> {transfer, [outside(m) | settled]}
        {m, _} -> {transfer, [m | settled]}
      end
    end)
    |> then(fn {transfer, settled} -> {Enum.reverse(transfer), Enum.reverse(settled)} end)
  end

  # The request was made and answered "not found", and the answer was right —
  # but the reason it was right is that nothing will ever build this here.
  defp outside(metrics), do: %{metrics | bucket: :not_for_env, reason: nil}

  @doc """
  The phase as the run ended: `settled` and the second pass's `transferred`
  metrics in place of the first pass's list, the tally recounted from them, and
  the span extended by the second pass's — the mix phase took both.
  """
  def merge(%Metrics.Phase{} = phase, settled, transferred, second_span_us) do
    units = settled ++ transferred

    tally =
      Enum.reduce(units, %{}, fn %Metrics.Unit{bucket: bucket}, tally ->
        Report.count(tally, phase.direction, bucket)
      end)

    %{phase | units: units, tally: tally, span_us: phase.span_us + second_span_us}
  end
end
