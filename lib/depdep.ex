defmodule Depdep do
  @moduledoc """
  A content-addressed store for compiled Elixir dependencies.

  Each dependency is stored as its own object, keyed by a recursive Merkle hash
  over its entire input closure, so a package is compiled once per distinct build
  and restored everywhere else. See `Depdep.Key` for why the hash recurses and
  `Depdep.Archive` for what an object contains.

  ## Harness properties

    * **Fail-safe toward more work.** Every failure mode — no credentials, an
      unreachable store, an unparseable lock, a dependency cycle, a git
      dependency whose closure cannot be known — skips the dependency and lets
      Mix compile it. Depdep can never make a build fail or, worse, succeed
      wrongly. It is a cache; a cold cache is slow, and that is all it is.
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
    with {:ok, lock} <- Depdep.Lock.read(Path.join([root, project, "mix.lock"])),
         config = Depdep.Config.read(Path.join(root, project), env, root),
         {:ok, keys} <- Depdep.Key.compute(lock, config, Depdep.Key.toolchain(env)) do
      {:ok, keys, lock}
    else
      {:error, {:cycle, name}} -> {:error, "dependency cycle through #{name}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
