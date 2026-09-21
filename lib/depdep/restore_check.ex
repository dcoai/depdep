defmodule Depdep.RestoreCheck do
  @moduledoc """
  After the second pass, ask Mix whether it would keep what was restored.

  A restore puts `deps/<name>` and `_build/<env>/lib/<name>` on disk with the
  manifests the pusher's Mix wrote. The consumer's Mix then judges the
  dependency by its own rules — the lock entry recorded in
  `.mix/compile.elixir_scm`, the Elixir and OTP it was built with, the `.app`
  file's version and `compile_env` — and a dependency that fails any of them
  is one Mix will rebuild, or worse, one it will not load while compiling its
  dependents. uficap's first pipeline hit the second: `--compile-deps` named
  `req` to Mix with a restored `mint` that Mix did not consider built, and
  `req` failed on `Mint.TransportError` (#85).

  Depdep never asked. This asks, with the same call `mix deps` makes, and a
  restored unit Mix would rebuild is re-bucketed as a **miss** with Mix's own
  reason: the store did not save it, and `--compile-deps` then names it to
  `mix deps.compile` like any miss, in Mix's order, so a dependent compiles
  against a dependency Mix has just built. The count is on the summary line
  and posted as `depdep.rebuilt_after_restore`: a value above zero means the
  key missed an input, the day it happens.
  """

  alias Depdep.{Metrics, Report, Unit}

  @doc """
  Mix's verdict on every unit, per member: `%{label => :ok | {:rebuild, why}}`.

  One converge per member (`Depdep.Deps.converged/2`), inside the member's
  project, so the answer reflects the disk as the restore left it.
  A unit Mix does not list — outside the env, or not a dependency at all —
  is absent from the map and left alone.
  """
  def statuses(units, env) do
    units
    |> Enum.group_by(& &1.context.project_dir)
    |> Enum.flat_map(fn {dir, member_units} ->
      by_app =
        dir
        |> Depdep.Deps.converged(env)
        |> Map.new(fn dep -> {Atom.to_string(dep.app), verdict(dep)} end)

      for unit <- member_units, verdict = Map.get(by_app, unit.name), verdict != nil do
        {Unit.label(unit), verdict}
      end
    end)
    |> Map.new()
  end

  defp verdict(%Mix.Dep{status: {:ok, _}}), do: :ok
  defp verdict(dep), do: {:rebuild, Mix.Dep.format_status(dep)}

  @doc """
  Re-buckets restored units Mix would rebuild: `{phase, [{label, reason}]}`.

  Only `pulled` and `present` units are in question — a miss is already a
  miss, and a skipped unit was never restored. A rebuilt unit's `saved_us`
  goes: the store saved nothing here.
  """
  def apply(%Metrics.Phase{} = phase, verdicts) do
    {units, rebuilt} =
      Enum.map_reduce(phase.units, [], fn unit, acc ->
        case {unit.bucket, Map.get(verdicts, unit.label)} do
          {bucket, {:rebuild, why}} when bucket in [:pulled, :present] ->
            reason = "rebuilt — " <> why

            {%{unit | bucket: :missing, reason: reason, rebuilt: true, saved_us: nil},
             [{unit.label, reason} | acc]}

          _ ->
            {unit, acc}
        end
      end)

    tally =
      Enum.reduce(units, %{}, fn %Metrics.Unit{bucket: bucket}, tally ->
        Report.count(tally, phase.direction, bucket)
      end)

    {%{phase | units: units, tally: tally}, Enum.reverse(rebuilt)}
  end

  @doc "How many restored units the run had to count as misses after all."
  def count(phases) do
    for %Metrics.Phase{units: units} <- phases,
        %Metrics.Unit{rebuilt: true} <- units,
        reduce: 0 do
      n -> n + 1
    end
  end
end
