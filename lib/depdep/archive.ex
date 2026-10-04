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

  `build_path` is where this member actually compiles, which is `_build/<env>`
  for almost everyone and is not for a project that sets `build_path` in its
  `mix.exs`. See `Depdep.BuildPath` — assuming the common case here meant
  restoring into a directory Mix never read, silently.

  Returned rather than inlined so `--pull` and `--push` cannot disagree about
  what an object contains.
  """
  def trees(name, build_path),
    do: [Path.join("deps", name), Path.join([build_path, "lib", name])]

  @doc "Files are added in sorted order so the archive is a function of its contents."
  def create(project_dir, name, build_path, dest),
    do: create_trees(project_dir, trees(name, build_path), dest, name)

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

  @doc """
  Extracts into the project directory, recreating the trees beneath it.

  **A restore replaces the trees it carries; it never extracts over what is
  there.** `trees` — `trees/2`'s answer, the same list `create/4` archived —
  are removed first. Two reasons, one of them a defect this used to have:
  git writes `.git/objects/*` read-only, and a git dependency is only ever
  restored after `mix deps.get` has cloned it, so extracting over the
  checkout answered `{:error, :eacces}` on every consumer and the unit was
  built from source as if the store had missed (#98). And leftovers from an
  earlier build under the same path are not part of the object; a restore
  that keeps them is the object plus something nobody asked for.
  """
  def extract(source, project_dir, trees) do
    File.mkdir_p!(project_dir)
    Enum.each(trees, &File.rm_rf!(Path.join(project_dir, &1)))

    # Staged inside the project so every move below is a same-filesystem rename
    # rather than a copy: an object can be hundreds of megabytes. `.depdep/` is
    # already depdep's own directory in a consumer (`--git-mirror-dir`).
    staging =
      Path.join([project_dir, ".depdep", "restore-#{:erlang.unique_integer([:positive])}"])

    File.mkdir_p!(staging)

    result =
      with :ok <- untar(source, staging),
           :ok <- place(staging, project_dir, trees) do
        :ok
      end

    File.rm_rf!(staging)
    result
  end

  defp untar(source, into) do
    case :erl_tar.extract(String.to_charlist(source), [
           :compressed,
           {:cwd, String.to_charlist(into)}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # **Each tree is moved to where THIS member builds, not where the pusher did**
  # (#131). An object's entry names are relative to the pusher's project root, so
  # the pusher's `build_path` is baked into them: metresis compiles at
  # `_build/sqlite/test` (`build_path: "_build/#{db_backend()}"`), so its objects
  # carry `_build/sqlite/test/lib/plug/…`. The key has no build-path input — and
  # should not, since the bytes do not differ — so metresis and a consumer
  # building at `_build/test` share one object.
  #
  # Extracting that in place put the build tree where the consumer's Mix never
  # looks. `Mix.Dep.Loader.validate_manifest/1` then read no manifest at
  # `opts[:build]`, returned `:error`, and reported "the dependency build is
  # outdated" — the same sentence it uses for a lock mismatch, which is why this
  # cost days to find. Measured: three objects for `plug 1.20.3` in the live
  # store, carrying `_build/test`, `_build/sqlite/test` and `_build/sqlite/prod`,
  # every one recording a lock identical to the consumer's.
  #
  # A tree the archive does not carry is an error rather than a partial restore:
  # the caller counts the unit as a miss and compiles it, which is the fail-safe
  # direction. Silently leaving it absent is the wrong-restore this exists to
  # prevent. So is an ambiguous match.
  defp place(staging, project_dir, trees) do
    dirs = staged_dirs(staging)

    with {:ok, sources} <- resolve(trees, dirs, staging) do
      Enum.each(sources, fn {tree, from} ->
        to = Path.join(project_dir, tree)
        File.mkdir_p!(Path.dirname(to))
        File.rm_rf!(to)
        :ok = File.rename(from, to)
      end)

      :ok
    end
  end

  # Every source is resolved from one listing BEFORE anything moves, so a rename
  # cannot invalidate a path still to be used.
  defp resolve(trees, dirs, staging) do
    Enum.reduce_while(trees, {:ok, []}, fn tree, {:ok, acc} ->
      case source_for(tree, trees, dirs, staging) do
        {:ok, from} -> {:cont, {:ok, [{tree, from} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # At its own path when the pusher built where this member does, which is the
  # common case and needs no search.
  #
  # Otherwise by the tree's last two segments — everything before them is the
  # pusher's build path. **A candidate nested inside another of the expected
  # trees is not a match**, and that is not a detail: a dependency's own source
  # commonly holds `lib/<name>`, so `deps/plug/lib/plug` has the same last two
  # segments as `_build/test/lib/plug`. Taking it moved the source tree and left
  # the next rename with nothing — found only by running against a real object.
  defp source_for(tree, trees, dirs, staging) do
    exact = Path.join(staging, tree)

    if File.dir?(exact) do
      {:ok, exact}
    else
      others = for t <- trees, t != tree, do: t <> "/"

      candidates =
        for {rel, dir} <- dirs,
            tail(rel) == tail(tree),
            not Enum.any?(others, &String.starts_with?(rel, &1)),
            do: dir

      case candidates do
        [one] ->
          {:ok, one}

        [] ->
          listing = dirs |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(", ")

          {:error, "the object carries no tree for #{tree} [staging=#{staging} dirs=#{listing}]"}

        many ->
          {:error, "the object carries #{length(many)} candidates for #{tree}, so none is chosen"}
      end
    end
  end

  # Relative path to absolute, for every directory in the staging area.
  defp staged_dirs(staging) do
    staging
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(fn dir -> {Path.relative_to(dir, staging), dir} end)
  end

  defp tail(path), do: path |> Path.split() |> Enum.take(-2) |> Path.join()

  @doc "Both trees present? A half-present dependency is treated as absent."
  def complete?(project_dir, name, build_path),
    do: name |> trees(build_path) |> Enum.all?(&File.dir?(Path.join(project_dir, &1)))
end
