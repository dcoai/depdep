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

    root
    |> Depdep.Layout.projects(opts)
    |> Enum.reduce({[], []}, fn project, {units, warnings} ->
      case Depdep.keys_for(root, project, env) do
        {:ok, keys, lock} ->
          {units ++ units_for(root, project, env, keys, lock), warnings}

        {:error, reason} ->
          {units, warnings ++ ["#{project}: #{reason} — every dependency will be compiled"]}
      end
    end)
    |> then(fn {units, warnings} -> {:ok, units, warnings} end)
  end

  defp units_for(root, project, env, keys, lock) do
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
        context: %{project_dir: project_dir, name: name, env: env}
      }
    end)
  end

  # A skipped dependency has no key, so it has no object and no version column.
  defp object(name, entry, {:key, hash}), do: Depdep.Key.object(name, entry, hash)
  defp object(_name, _entry, {:skip, _reason}), do: nil

  defp detail(entry, {:key, _hash}), do: Depdep.Lock.version(entry)
  defp detail(_entry, {:skip, _reason}), do: "-"

  @impl true
  def present?(%Unit{context: %{project_dir: dir, name: name, env: env}}),
    do: Depdep.Archive.complete?(dir, name, env)

  @impl true
  def restore(%Unit{context: %{project_dir: dir}}, tmp),
    do: Depdep.Archive.extract(tmp, dir)

  @impl true
  def collect(%Unit{context: %{project_dir: dir, name: name, env: env}}, tmp),
    do: Depdep.Archive.create(dir, name, env, tmp)
end
