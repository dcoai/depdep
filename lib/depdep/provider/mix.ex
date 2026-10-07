defmodule Depdep.Provider.Mix do
  @moduledoc """
  Compiled Elixir dependencies: the provider depdep was originally all of.

  Everything specific to Mix lives behind this module — `Depdep.Key`'s recursive
  Merkle hash, `Depdep.Deps` (the one place Mix itself is asked), `Depdep.Lock`,
  `Depdep.Config`, `Depdep.Layout`'s poncho discovery, and `Depdep.Archive`'s
  two-trees-or-it-recompiles rule. None of it
  changed when the seam was extracted, and `Depdep.Provider.MixTest` asserts as
  much: a key or an object path that moves here silently retires every object in
  every consumer's store.

  A unit is one dependency of one project. `:group` is the project directory, so
  a poncho's eleven members each contribute their own `ash` and each is reported
  under its own name.
  """

  @behaviour Depdep.Provider

  alias Depdep.Provider.Mix.Source
  alias Depdep.Unit

  @impl true
  def enumerate(opts) do
    root = Keyword.fetch!(opts, :root)
    env = Keyword.fetch!(opts, :env)
    direction = Keyword.get(opts, :direction, :pull)

    {projects, notes} = Depdep.Layout.projects(root, opts)

    projects
    |> Enum.reduce({[], notes}, fn project, {units, warnings} ->
      case Depdep.keys_for(root, project, env) do
        {:ok, keys, deps} ->
          case Depdep.BuildPath.for_project(Path.join(root, project), env) do
            {:ok, build_path} ->
              {units ++ units_for(root, project, env, keys, deps, direction, build_path),
               warnings ++ unsettled(project, env, deps)}

            {:error, reason} ->
              {units, warnings ++ ["#{project}: #{reason} — skipping it"]}
          end

        {:error, reason} ->
          {units, warnings ++ ["#{project}: #{reason} — every dependency will be compiled"]}
      end
    end)
    |> then(fn {units, warnings} -> {:ok, units, warnings} end)
  end

  # Before `mix deps.get` Mix's list is incomplete, so nothing is called
  # inactive and every lock entry is requested — the fail-safe direction.
  # Said once per member so the reader of `missing N` knows the second pass
  # (`--mix-get`) is what settles it.
  defp unsettled(project, env, deps) do
    case Enum.count(deps, fn {_, dep} -> dep.active? == nil end) do
      0 ->
        []

      n ->
        [
          "#{project}: dependencies not fetched yet, so #{n} lock entries are requested " <>
            "whether or not MIX_ENV=#{env} builds them — --mix-get settles that after deps.get"
        ]
    end
  end

  defp units_for(root, project, env, keys, deps, direction, build_path) do
    project_dir = Path.join(root, project)

    keys
    |> Enum.sort()
    |> Enum.map(fn {name, keyed} ->
      %{entry: entry, active?: active?} = Map.fetch!(deps, name)
      resolution = resolve(keyed, active?, env)

      %Unit{
        group: project,
        name: name,
        detail: detail(entry, resolution),
        resolution: resolution,
        object: object(name, entry, resolution),
        context: %{
          project_dir: project_dir,
          name: name,
          env: env,
          direction: direction,
          build_path: build_path,
          git_origin: Depdep.Lock.repo(entry)
        }
      }
    end)
    |> then(&(&1 ++ source_units(project, project_dir, deps, direction)))
  end

  # **A git dependency's SOURCE, restorable in the first pass** (#164, for #151). Its
  # build is still skipped here — its children are unknown until `mix deps.get` — but
  # its source needs none of that: the lock names an exact commit, so
  # `Depdep.Provider.Mix.Source` keys it without recursion. Restored before `deps.get`,
  # Mix finds the checkout at the locked rev and does not clone it, which is about 35 s
  # of a 52 s fully warm run on dco-tek/snow-removal-tracker-ex.
  #
  # The name carries `(source)` so the label does not collide with the build unit's.
  # `Depdep.Unit.label/1` keys the restore check, the second pass and the compile
  # selection, and two units of one dependency sharing a label would silently overwrite
  # each other in all three. Build-unit labels are untouched, which also keeps the
  # metrics metresis already holds continuous.
  defp source_units(project, project_dir, deps, direction) do
    for {name, %{entry: entry}} <- Enum.sort(deps),
        {:ok, commit} <- [Source.commit(entry)],
        {:ok, object} <- [Source.object(entry)] do
      %Unit{
        group: project,
        name: "#{name} (source)",
        detail: String.slice(commit, 0, 12),
        resolution: {:key, commit},
        object: object,
        context: %{
          kind: :source,
          project_dir: project_dir,
          name: name,
          commit: commit,
          direction: direction,
          git_origin: Depdep.Lock.repo(entry)
        }
      }
    end
  end

  # A dependency this env never builds is decided before its key matters: there
  # is nothing to fetch and nothing to offer, whatever the key says. `nil` —
  # Mix's list incomplete before `deps.get` — keeps the key: requested, and
  # settled by the second pass.
  defp resolve(_keyed, false, env), do: {:not_for_env, env}
  defp resolve(keyed, _active?, _env), do: keyed

  # A skipped or excluded dependency has no key, so it has no object and no
  # version column.
  defp object(name, entry, {:key, hash}), do: Depdep.Key.object(name, entry, hash)
  defp object(_name, _entry, _unkeyed), do: nil

  defp detail(entry, {:key, _hash}), do: Depdep.Lock.version(entry)
  defp detail(_entry, _unkeyed), do: "-"

  @doc """
  Whether there is anything to do — and the two directions ask different
  questions, which is not a nicety.

  **Pull** asks "do I already have the RIGHT tree?". Presence alone cannot tell a
  stale dependency from a current one: bump a version over a warm `_build` and
  both directories still exist, so the pull is skipped, `mix deps.get` writes the
  new source over the old build, and Mix recompiles — while the exact right
  object sits in the store, unrequested. Measured in `dco-tek/bizex` on an
  `ash 3.32.3 -> 3.33.0` bump: `pulled 0, missing 7, skipped 557`, 14
  dependencies recompiled. So the pull compares the recorded key with the
  computed one.

  **Push** asks "is there a tree here to upload?", and must NOT consider the key.
  A locally built tree that was never restored has no note; requiring one here
  would make `Depdep.Report.outcome(:push, _, false)` report `not built here` for
  every dependency and upload nothing, forever, silently.
  """
  @impl true
  # Called before `Depdep.Report.outcome/3` decides anything, so it is reached
  # for skipped units too. Its value is unused for those.
  def present?(%Unit{resolution: {:skip, _reason}}), do: false
  # A source is present when the checkout is at the locked commit. Asked of git rather
  # than recorded in a note: the commit IS the identity, so git already holds the answer
  # and a note could disagree with the checkout beside it.
  def present?(%Unit{context: %{kind: :source, commit: commit}} = unit),
    do: head_of(checkout(unit)) == {:ok, commit}

  def present?(%Unit{resolution: {:not_for_env, _env}}), do: false

  def present?(%Unit{context: %{direction: :push}} = unit), do: trees?(unit)

  def present?(%Unit{resolution: {:key, hash}} = unit),
    do: trees?(unit) and recorded_key(unit) == hash

  defp project_dir(%Unit{context: %{project_dir: dir}}), do: dir

  defp checkout(%Unit{context: %{project_dir: dir, name: name}}),
    do: Path.join([dir, "deps", name])

  # `git rev-parse HEAD` in the checkout, or `:error` for anything that is not a
  # repository at a commit — which includes an absent directory, so no File check first.
  defp head_of(checkout) do
    case System.cmd("git", ["-C", checkout, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _status} -> :error
    end
  end

  defp trees?(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}}),
    do: Depdep.Archive.complete?(dir, name, build_path)

  # **A restored git checkout keeps the PUSHER's `origin`, and Mix compares it**
  # (#123). `Mix.SCM.Git.lock_status/1` asks for `get_lock_repo(lock) == origin`
  # as well as the rev, comparing the lock's URL to `remote.origin.url` as
  # strings — so a peer that spells the same repository differently gets
  # `:mismatch`, which Mix reports as "lock mismatch: the dependency is out of
  # date". That is also its wording for a genuine lock difference, which is why
  # this looked like a key defect for weeks.
  #
  # The URL is deliberately absent from the key (`Depdep.Lock.repo/1`): the sha
  # identifies the content, so one object serves every spelling. Measured in the
  # live store: extla's objects for one commit exist under both
  # `git@…:dco-tek/extla.git` and `https://…/dco-tek/extla.git`, while extc locks
  # the https spelling and visualize, visualize2 and exio lock the ssh one.
  #
  # So the origin is rewritten to THIS consumer's lock URL on the way in. A hex
  # dependency has no `git_origin` and no git command runs for it.
  # The source's one tree is `deps/<name>`, with its `.git`. The origin is adopted the
  # way a restored build's is (#144): the object carries the pusher's, and Mix compares
  # it as a string.
  @impl true
  def restore(%Unit{context: %{kind: :source, name: name}} = unit, tmp) do
    with :ok <- Depdep.Archive.extract(tmp, project_dir(unit), [Path.join("deps", name)]) do
      adopt_origin(unit)
    end
  end

  @impl true
  def restore(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}} = unit, tmp) do
    with :ok <- Depdep.Archive.extract(tmp, dir, Depdep.Archive.trees(name, build_path)) do
      adopt_origin(unit)
    end
  end

  # An unrewritten origin is a refused restore, not a wrong one — but refusing
  # costs a compile for no reason, so a failure here is reported as an error and
  # the unit becomes a miss. Leaving a foreign origin in place silently is the one
  # option not taken.
  defp adopt_origin(%Unit{context: %{git_origin: nil}}), do: :ok

  defp adopt_origin(%Unit{context: %{git_origin: url, project_dir: dir, name: name}}) do
    checkout = Path.join([dir, "deps", name])

    if File.dir?(Path.join(checkout, ".git")) do
      case System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", url],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          :ok

        {out, status} ->
          {:error,
           "could not set deps/#{name}'s origin to #{url} (git exited #{status}: " <>
             "#{out |> String.split("\n", trim: true) |> List.last() |> Kernel.||("no output") |> String.slice(0, 160)})"}
      end
    else
      # No `.git` to point anywhere. Mix will read no origin and rebuild, which
      # `Depdep.RestoreCheck` turns into a miss with Mix's own reason.
      :ok
    end
  end

  @impl true
  def collect(%Unit{context: %{kind: :source, name: name}} = unit, tmp),
    do:
      Depdep.Archive.create_trees(
        project_dir(unit),
        [Path.join("deps", name)],
        tmp,
        "#{name}'s source"
      )

  @impl true
  def collect(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}}, tmp),
    do: Depdep.Archive.create(dir, name, build_path, tmp)

  # Nothing to record: `present?` asks git for the commit, so there is no note that
  # could drift from the checkout.
  @impl true
  def record(%Unit{context: %{kind: :source}}), do: :ok

  @impl true
  def record(%Unit{resolution: {:skip, _reason}}), do: :ok
  def record(%Unit{resolution: {:not_for_env, _env}}), do: :ok

  def record(%Unit{resolution: {:key, hash}} = unit) do
    path = note_path(unit)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, hash) do
      :ok -> :ok
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  defp recorded_key(unit) do
    case File.read(note_path(unit)) do
      {:ok, hash} -> String.trim(hash)
      {:error, _} -> nil
    end
  end

  # Beside the build, never inside it. `Depdep.Archive.trees/2` does not cover
  # this path, so the note is never tarred into an object — which keeps a stored
  # object exactly what `mix compile` produced, and keeps `collect/2` from
  # writing into a tree it is only supposed to read. It still lives under
  # `_build`, so everything that cleans a build cleans it too.
  # Beside the build, wherever the build is — so the note moves with the object.
  # Left at `_build/<env>` while the trees moved, every pull would miss forever
  # and the key check would silently stop working.
  defp note_path(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}}),
    do: Path.join([dir, build_path, ".depdep", name])
end
