defmodule Depdep.Provider.Mix do
  @moduledoc """
  Compiled Elixir dependencies: the provider depdep was originally all of.

  Everything specific to Mix lives behind this module — `Depdep.Key`'s recursive
  Merkle hash, `Depdep.Lock`, `Depdep.Config`, `Depdep.Layout`'s poncho
  discovery, and `Depdep.Archive`'s two-trees-or-it-recompiles rule. None of it
  changed when the seam was extracted, and `Depdep.Provider.MixTest` asserts as
  much: a key or an object path that moves here silently retires every object in
  every consumer's store.

  A unit is one dependency of one project. `:group` is the project directory, so
  a poncho's eleven members each contribute their own `ash` and each is reported
  under its own name.
  """

  @behaviour Depdep.Provider

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
        {:ok, keys, lock} ->
          case Depdep.BuildPath.for_project(Path.join(root, project), env) do
            {:ok, build_path} ->
              {units ++ units_for(root, project, env, keys, lock, direction, build_path),
               warnings}

            {:error, reason} ->
              {units, warnings ++ ["#{project}: #{reason} — skipping it"]}
          end

        {:error, reason} ->
          {units, warnings ++ ["#{project}: #{reason} — every dependency will be compiled"]}
      end
    end)
    |> then(fn {units, warnings} -> {:ok, units, warnings} end)
  end

  defp units_for(root, project, env, keys, lock, direction, build_path) do
    project_dir = Path.join(root, project)

    keys
    |> Enum.sort()
    |> Enum.map(fn {name, resolution} ->
      entry = Map.fetch!(lock, name)

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
          build_path: build_path
        }
      }
    end)
  end

  # A skipped dependency has no key, so it has no object and no version column.
  defp object(name, entry, {:key, hash}), do: Depdep.Key.object(name, entry, hash)
  defp object(_name, _entry, {:skip, _reason}), do: nil

  defp detail(entry, {:key, _hash}), do: Depdep.Lock.version(entry)
  defp detail(_entry, {:skip, _reason}), do: "-"

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

  def present?(%Unit{context: %{direction: :push}} = unit), do: trees?(unit)

  def present?(%Unit{resolution: {:key, hash}} = unit),
    do: trees?(unit) and recorded_key(unit) == hash

  defp trees?(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}}),
    do: Depdep.Archive.complete?(dir, name, build_path)

  @impl true
  def restore(%Unit{context: %{project_dir: dir}}, tmp),
    do: Depdep.Archive.extract(tmp, dir)

  @impl true
  def collect(%Unit{context: %{project_dir: dir, name: name, build_path: build_path}}, tmp),
    do: Depdep.Archive.create(dir, name, build_path, tmp)

  @impl true
  def record(%Unit{resolution: {:skip, _reason}}), do: :ok

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
