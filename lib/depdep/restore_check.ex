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
  alias Depdep.RestoreCheck.Manifest

  @doc """
  Mix's verdict on every unit, per member: `%{label => :ok | {:rebuild, why}}`.

  A second converge, on purpose. The one that keyed the units
  (`Depdep.Deps.read/2`) ran before the transfer, and what it saw is not what
  the restore left: the manifests Mix judges arrive *with* the objects. Two
  questions, two moments, two converges — folding them would ask Mix about a
  disk it has not seen yet (#96).

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
        |> Depdep.Deps.converged(env, compile_env: true)
        |> Map.new(fn dep -> {Atom.to_string(dep.app), verdict(dep)} end)

      for unit <- member_units, verdict = Map.get(by_app, unit.name), verdict != nil do
        {Unit.label(unit), verdict}
      end
    end)
    |> Map.new()
  end

  # A rebuild verdict carries what `--explain-rebuilt` needs: the three values
  # `Mix.Dep.Loader.validate_manifest/1` compares, and where the manifest is
  # (#135). Mix's sentence says a build is outdated without saying which of them
  # differed, and for the commonest status it cannot — one message, two causes.
  defp verdict(%Mix.Dep{status: {:ok, _}}), do: :ok

  defp verdict(%Mix.Dep{} = dep) do
    {:rebuild, Mix.Dep.format_status(dep), evidence(dep)}
  end

  defp evidence(%Mix.Dep{scm: scm, opts: opts, app: app}) do
    %{
      build: opts[:build],
      expected: {{System.version(), :erlang.system_info(:otp_release)}, scm, opts[:lock]},
      compile_env: compile_env_evidence(opts[:build], app)
    }
  end

  # **Captured here, not in `explain/1`** (#162). Mix decides `compile_env` against the
  # application env in the asking VM, and `Depdep.Deps.converged/3` has the member's
  # config loaded only for the duration of the converge — which is where this runs.
  # Comparing later would compare against an empty env and name every entry as
  # differing, which is #161's defect wearing a diagnostic's clothes.
  #
  # Cheap when there is nothing to say: one `.app` read per dependency Mix rejected,
  # and `explain/1` is off by default but this is not, because by the time the flag is
  # read the window has closed.
  defp compile_env_evidence(nil, _app), do: :absent

  defp compile_env_evidence(build, app) do
    case Manifest.compile_env(build, app) do
      {:ok, entries} -> Manifest.compile_env_differences(entries)
      other -> other
    end
  end

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
          {bucket, {:rebuild, why, _evidence}} when bucket in [:pulled, :present] ->
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

  @doc """
  Lines explaining one rebuild, for `--explain-rebuilt` (#134).

  Returned rather than printed, so IO stays in `Depdep.CLI` and every line is
  asserted in a test without capturing output. `[]` when the manifest agrees with
  what Mix expected — a rebuild for a reason outside the manifest, which is worth
  seeing as the absence of an explanation rather than a wrong one.
  """
  def explain(%{build: build, expected: expected} = evidence) do
    path = Manifest.path(build)

    case Manifest.read(build) do
      :absent ->
        ["manifest: #{path} — ABSENT, so Mix recompiles"]

      :unreadable ->
        ["manifest: #{path} — UNREADABLE: it does not hold the term Mix writes"]

      {:ok, stored} ->
        verdicts = Manifest.compare(stored, expected)

        if Manifest.differs?(verdicts),
          do: ["manifest: #{path}"] ++ Enum.flat_map(verdicts, &field_line/1),
          else: ["manifest: #{path} — every field agrees"] ++ compile_env_lines(evidence)
    end
  end

  def explain(_no_evidence), do: []

  # The compile env is the OTHER cause of "the dependency compile environment is
  # outdated", and until #162 the diagnostic could only say the manifest agreed and
  # stop — which is why #141 had to be found by reading Mix's source instead.
  defp compile_env_lines(%{compile_env: [_ | _] = differences}) do
    for {app, keys, recorded, current} <- differences do
      "  compile env: #{entry(app, keys)} was #{value(recorded)}, is #{value(current)}"
    end
  end

  defp compile_env_lines(%{compile_env: :unreadable}),
    do: ["  compile env: the .app file is not the term Mix writes"]

  defp compile_env_lines(_none), do: ["  the rebuild is for another reason"]

  defp entry(app, [key]), do: "{#{inspect(app)}, #{inspect(key)}}"
  defp entry(app, keys), do: "{#{inspect(app)}, #{inspect(keys)}}"

  defp value({:ok, v}), do: inspect(v, limit: 8)
  defp value(:error), do: "unset"

  defp field_line({field, :same}), do: ["  #{pad(field)} same"]

  defp field_line({field, {:differs, detail}}) do
    [
      "  #{pad(field)} DIFFERS",
      "    stored   #{inspect(detail.stored, limit: 8)}",
      "    expected #{inspect(detail.expected, limit: 8)}"
    ] ++
      element_line(detail)
  end

  # The index is the deliverable: 2 or 3 is the version or checksum, 5 the
  # dependency list, 6 the repo, 7 the outer checksum — and #122's collision
  # table maps each to a cause.
  defp element_line(%{element: :shape}),
    do: ["    the two are not tuples of one size, so no element is comparable"]

  defp element_line(%{element: index}) when is_integer(index),
    do: ["    first differing tuple element: #{index}"]

  defp element_line(_detail), do: []

  # Displayed as Mix talks about them rather than as the atoms they are: a reader
  # comparing this against `Mix.Dep.Loader.validate_manifest/1` should see the
  # same words.
  defp pad(field), do: String.pad_trailing(label(field), 11)

  defp label(:elixir_otp), do: "elixir/otp"
  defp label(field), do: to_string(field)

  @doc "How many restored units the run had to count as misses after all."
  def count(phases) do
    for %Metrics.Phase{units: units} <- phases,
        %Metrics.Unit{rebuilt: true} <- units,
        reduce: 0 do
      n -> n + 1
    end
  end
end
