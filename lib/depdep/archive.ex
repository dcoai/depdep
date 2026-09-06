defmodule Depdep.Archive do
  @moduledoc """
  Tar one dependency's SOURCE and BUILD together, and put them back together.

  An object holds both `deps/<dep>/` and `_build/<env>/lib/<dep>/`, rooted at the
  project directory. **Shipping only `_build` does not work, and the failure is
  silent — it restores fine and then recompiles everything anyway.**

  Mix decides a dependency is stale by comparing its SOURCE mtimes against the
  build manifest. Restore `_build` alone and `mix deps.get` then fetches source
  fresh, so every source file is newer than the manifest that was just restored,
  every dependency is stale, and Mix recompiles the lot. Measured before the fix:
  a project with all 16 dependencies restored still reported

      ==> stream_data  ==> ymlr  ==> multigraph  ==> ets  ==> iterex
      ==> decimal  ==> jason  ==> spark  ==> yaml_elixir  ==> ecto
      ==> splode  ==> reactor  ==> crux  ==> ash

  and the pipeline came out 9% SLOWER than having no store at all.

  Carrying both trees in one archive fixes it twice over: `erl_tar` restores the
  recorded mtimes, so source and manifest keep the ordering they had when the
  build was made; and `mix deps.get` finds the source already present, so it does
  not refetch and cannot introduce a newer mtime. It also removes the source
  download entirely, which makes the job hermetic.

  `_build/<env>/consolidated/` is deliberately NOT part of any object. Protocol
  consolidation is derived from the union of every beam in the project, so it is
  a property of the project and not of any one dependency. It is also cheap to
  regenerate, and getting it wrong looks exactly like a silent protocol
  degradation.
  """

  @doc """
  The two trees an object carries, relative to the project directory.

  Returned rather than inlined so `--pull` and `--push` cannot disagree about
  what an object contains.
  """
  def trees(name, env),
    do: [Path.join("deps", name), Path.join(["_build", to_string(env), "lib", name])]

  @doc "Files are added in sorted order so the archive is a function of its contents."
  def create(project_dir, name, env, dest),
    do: create_trees(project_dir, trees(name, env), dest, name)

  @doc """
  Tars `trees` — paths relative to `base_dir` — into `dest`.

  The generic half of `create/4`, so a provider that stores something other than
  a dependency's two trees does not have to write its own `:erl_tar` call.
  `extract/2` was already generic and is the other half.
  """
  def create_trees(base_dir, trees, dest, label \\ "this unit") do
    paths = Enum.flat_map(trees, &Path.wildcard(Path.join([base_dir, &1, "**"]), match_dot: true))

    entries =
      (Enum.filter(paths, &File.regular?/1) ++ empty_dirs(paths))
      |> Enum.sort()
      |> Enum.map(fn file ->
        {file |> Path.relative_to(base_dir) |> String.to_charlist(), String.to_charlist(file)}
      end)

    if entries == [] do
      {:error, "nothing to archive for #{label}"}
    else
      case :erl_tar.create(String.to_charlist(dest), entries, [:compressed]) do
        :ok -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # An empty directory is not nothing. A bare git repository ships `refs/heads`,
  # `objects/pack` and others with no files in them, and `git fsck` rejects a
  # repository that has lost them — the tar restores perfectly and produces
  # something git will not accept. Carrying only regular files silently dropped
  # them.
  #
  # `:erl_tar` adds a directory recursively, so an EMPTY one contributes exactly
  # its own entry and nothing else. A non-empty directory is left out here: its
  # files are already listed, and tar creates the parents they need.
  defp empty_dirs(paths) do
    Enum.filter(paths, fn path -> File.dir?(path) and File.ls!(path) == [] end)
  end

  @doc "Extracts into the project directory, recreating both trees beneath it."
  def extract(source, project_dir) do
    File.mkdir_p!(project_dir)

    case :erl_tar.extract(String.to_charlist(source), [
           :compressed,
           {:cwd, String.to_charlist(project_dir)}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Both trees present? A half-present dependency is treated as absent."
  def complete?(project_dir, name, env),
    do: name |> trees(env) |> Enum.all?(&File.dir?(Path.join(project_dir, &1)))
end
