defmodule Depdep.Compile do
  @moduledoc """
  Compiles exactly the dependencies the pull could not restore, timed.

  The dashboard could say what depdep *cost* a job but not what it *saved*,
  and the saving is a per-dependency compile time — a number that exists only
  at the moment a miss is compiled. Depdep never occupied that moment: the
  consumer's `mix compile` did, after `deps.get`, and it prints no per-dependency
  timing (#59).

  So after `--mix-get` has fetched the source, `--compile-deps` runs one
  `mix deps.compile <names>` per member, naming **only the misses**. depdep
  knows the list from its own pull; Mix is never asked about a restored unit,
  and the consumer's `mix compile` line, untouched, then finds every dependency
  up to date and compiles only the project. Output is forwarded unchanged and
  timestamped on arrival; `Depdep.Compile.Log` turns the boundaries into spans.

  ## The one place depdep may fail a pipeline

  A dependency that does not compile ends this run with Mix's exit status,
  after the summary line. That is not a hole in "failure is not an error": the
  failure is the consumer's own compile, surfaced one line earlier than it
  would have been, with the same error text. The store had nothing to do with
  it.

  ## Only what this env is known to build

  A miss is named to Mix only when the env walk said `:active` exactly. A unit
  still `:ambiguous` after the second pass — the graph could not be read, so a
  git dependency's children are unknown and an unreached entry *might* be one
  of them — was rightly requested from the store, but naming it to
  `mix deps.compile` under an env that does not build it is refused
  (`Unknown dependency X for environment Y`) and ends the run for nothing
  (#81). It is left to the consumer's own `mix compile`, and said so.

  ## What is recorded, and where

  Each measured unit's microseconds go to `<build_path>/.depdep/<name>.compile`,
  beside the key note `Depdep.Provider.Mix.record/1` writes — so a later
  `--push` finds the number without being told a path, and it lives under
  `_build` where everything that cleans a build cleans it too.
  """

  alias Depdep.Unit

  @doc """
  Which of `units` to compile, given the labels the pull left `:missing`:
  `{to_compile, held}`. `held` are misses whose env verdict is not exact.

  Given a predicate instead of labels — the no-store path, where a miss is
  anything absent that this env builds — the same split, the same rule.
  """
  def select(units, missing_labels) when is_list(missing_labels),
    do: select(units, &(Unit.label(&1) in missing_labels))

  def select(units, missing?) when is_function(missing?, 1) do
    units
    |> Enum.filter(missing?)
    |> Enum.split_with(&(&1.context.env_verdict == :active))
  end

  @doc "The one line a held unit gets, on either path."
  def held_warning(unit, env) do
    "#{Unit.label(unit)}: not compiled — may be outside MIX_ENV=#{env}, " <>
      "the dependency graph was not available"
  end

  @doc """
  Compiles `units` (misses of the mix provider, any members), returning
  `{status, %{label => {us, kind}}, unmeasured}`.

  `status` is the first non-zero Mix exit, or 0. `unmeasured` are the labels
  that were named but never appeared as a boundary in Mix's output — compiled
  inside a parent's compile, or by a tool that prints none — reported rather
  than guessed at.
  """
  def run(units, env) do
    units
    |> Enum.group_by(& &1.context.project_dir)
    |> Enum.sort()
    |> Enum.reduce({0, %{}, []}, fn {dir, member_units}, {status, measured, unmeasured} ->
      names = member_units |> Enum.map(& &1.name) |> Enum.sort()
      {exit_status, spans} = compile(dir, names, env)

      {measured, unmeasured} =
        Enum.reduce(member_units, {measured, unmeasured}, fn unit, {measured, unmeasured} ->
          case Map.fetch(spans, unit.name) do
            {:ok, {us, kind}} ->
              :ok = record(unit, us)
              {Map.put(measured, Unit.label(unit), {us, kind}), unmeasured}

            :error ->
              {measured, [Unit.label(unit) | unmeasured]}
          end
        end)

      {if(status == 0, do: exit_status, else: status), measured, Enum.reverse(unmeasured)}
    end)
  end

  # A port in line mode, so each line is stamped the moment it arrives rather
  # than when a chunk happens to flush. `System.cmd/3` hands over chunks.
  defp compile(dir, names, env) do
    mix = System.find_executable("mix") || raise "no mix on this machine"

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        {:cd, dir},
        {:env, [{~c"MIX_ENV", String.to_charlist(to_string(env))}]},
        {:args, ["deps.compile" | names]}
      ])

    {status, stamped} = collect(port, System.monotonic_time(:microsecond), [], "")
    {status, Depdep.Compile.Log.attribute(Enum.reverse(stamped))}
  end

  defp collect(port, origin, stamped, partial) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = partial <> chunk
        IO.puts(line)

        collect(
          port,
          origin,
          [{System.monotonic_time(:microsecond) - origin, line} | stamped],
          ""
        )

      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, origin, stamped, partial <> chunk)

      {^port, {:exit_status, status}} ->
        if partial != "", do: IO.puts(partial)
        {status, stamped}
    end
  end

  @doc "Where a unit's compile time is kept: beside its key note."
  def note_path(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}}),
    do: Path.join([dir, build_path, ".depdep", name <> ".compile"])

  @doc """
  Records `us` as the unit's compile time — measured here, or carried in from
  the object a pull restored, so a later run finds it without a request.
  """
  def record(unit, us) when is_integer(us) and us >= 0 do
    path = note_path(unit)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Integer.to_string(us))
  end

  @doc """
  The recorded compile time, `{:ok, us}` or `:none`.

  A note that does not parse as an integer is `:none` too: it is a number
  someone will read as time saved, and a guess is worse than a gap.
  """
  def read(unit) do
    with {:ok, contents} <- File.read(note_path(unit)),
         {us, ""} <- Integer.parse(String.trim(contents)) do
      {:ok, us}
    else
      _ -> :none
    end
  end

  @doc """
  What a hit saved: the compile it did not do, less what the transfer cost —
  never below zero, and `nil` when the object carried no compile time.

  A lower bound: `mix deps.get`'s source fetch was saved too and cannot be
  attributed to one unit, so it is left out.
  """
  def saved_us(nil, _transfer_us), do: nil
  def saved_us(compile_us, transfer_us), do: max(compile_us - transfer_us, 0)
end
