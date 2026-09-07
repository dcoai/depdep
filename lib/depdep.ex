defmodule Depdep do
  @moduledoc """
  A content-addressed store for build artifacts.

  What is stored, how it is keyed and where it belongs on disk are a
  `Depdep.Provider`'s business — compiled Elixir dependencies, Debian packages
  and git mirrors each answer those differently. The store, the concurrency and
  the harness properties below are common to all of them.

  This module holds what the mix provider needs: each dependency is stored as its
  own object, keyed by a recursive Merkle hash over its entire input closure, so
  a package is compiled once per distinct build and restored everywhere else. See
  `Depdep.Key` for why that hash recurses — and why nothing else here does — and
  `Depdep.Archive` for what such an object contains.

  ## Harness properties

    * **Fail-safe toward more work.** Every failure to reach or use the store —
      no credentials, an unreachable host, a wrong secret, a corrupt object, a
      dependency cycle, a git dependency whose closure cannot be known — skips
      the dependency and lets Mix compile it. The run exits 0 having cost at
      most a compile Mix was going to do anyway. It is a cache; a cold cache is
      slow, and that is all it is.

      **The limit of that promise, stated exactly.** Depdep reads two files it
      does not own, and neither is absorbed: a `mix.lock` that does not parse
      raises out of `Depdep.Lock.read/1`, an unreadable `config/config.exs`
      raises out of `Depdep.Config.read/3`, and the run exits non-zero. That is
      the right behaviour rather than a gap — an input depdep cannot read is one
      `mix deps.get` and `mix compile` cannot read either, so the build was
      going to fail at the next command regardless. Depdep fails it earlier and
      names the file. NO `try/rescue` is what keeps this honest: rescuing here
      would convert a broken project into a slow one and hide which file was
      wrong.

    * **Decisions are visible.** Every hit, miss and skip prints its reason to
      stderr, so a surprising result can be read rather than guessed at.
    * **Append-only.** The store's credentials should carry GetObject and
      PutObject and NOT DeleteObject. An object, once written, is immutable; the
      schema prefix is how the whole store is retired if it ever needs to be.
  """

  @doc """
  Project -> `{:ok, %{name => {:key, hash} | {:skip, reason}}, lock}` or `{:error, reason}`.
  """
  def keys_for(root, project, env) do
    project_dir = Path.join(root, project)

    with {:ok, lock} <- Depdep.Lock.read(Path.join(project_dir, "mix.lock")),
         config = Depdep.Config.read(project_dir, env, root),
         graph = graph_for(project_dir, env, lock),
         {:ok, keys} <- Depdep.Key.compute(lock, config, Depdep.Key.toolchain(env), graph) do
      {:ok, keys, lock}
    else
      {:error, {:cycle, name}} -> {:error, "dependency cycle through #{name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Two guards before shelling out, and both matter.
  #
  # There must be a git entry at all: a lock of hex entries already carries every
  # child, so asking Mix would be a subprocess per project to learn nothing.
  #
  # And every git dependency's source must already be on disk. `mix deps.tree`
  # cannot resolve a dependency it has not fetched, so before `mix deps.get` it
  # fails — slowly, and possibly over the network. That is the FIRST pass, every
  # run, once per project: measured at ~28 s across this project's own test
  # fixtures before the guard was added. Checking for `deps/<name>` costs a stat
  # and answers the same question.
  #
  # Without a graph the git dependency skips exactly as it always has, and the
  # second pass — after `deps.get` — is where this succeeds.
  defp graph_for(project_dir, env, lock) do
    git_deps =
      for {name, entry} <- lock, elem(entry, 0) == :git, do: name

    fetched? =
      git_deps != [] and
        Enum.all?(git_deps, &File.dir?(Path.join([project_dir, "deps", &1])))

    if fetched? do
      case Depdep.Graph.read(project_dir, env) do
        {:ok, graph} -> graph
        {:error, _reason} -> %{}
      end
    else
      %{}
    end
  end
end
