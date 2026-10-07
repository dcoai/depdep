defmodule Depdep.Provider.Mix.Source do
  @moduledoc """
  A git dependency's **source**, keyed on the repository and the locked commit.

  Separate from `Depdep.Key` on purpose. That key is a recursive Merkle hash over a
  compiled dependency's whole input closure, because compiled output depends on the
  output of everything below it. A *source* depends on nothing: a git lock entry is
  `{:git, url, rev, opts}` with `rev` an exact commit, so the bytes are determined by
  the commit alone — no children, no toolchain, no configuration, nothing to be wrong
  about. Putting it in `Depdep.Key` would invite someone to add the toolchain here,
  which would split the store for no difference in content.

  ## Why there is no hash

  The commit **is** the content address, so the object path carries it directly rather
  than a digest of it. That follows `Depdep.Provider.Git`, whose objects are named by
  their epoch for the same reason: when the identity is already short and readable,
  hashing it only makes the store harder to browse.

  ## Why the repository is normalised

  `Depdep.Provider.Git.slug/1` reduces `git@host:group/proj.git` and
  `https://host/group/proj.git` to one name, so **two consumers spelling the same
  repository differently share one object**. The alternative — keying on the URL as
  written — would store one copy of a commit per way of writing its address, which is
  #123's defect paid for in storage instead of in recompiles.

  ## What this exists for

  A git dependency is skipped in the first pass, because its children are unknown until
  `mix deps.get` has fetched it — so `deps.get` clones it from the network every run,
  and only the second pass restores its build. Measured on
  `dco-tek/snow-removal-tracker-ex`: about 35 s of a 52 s fully warm run, three clones,
  with nothing compiled. The source needs none of what the first pass lacks, so it can
  be restored before `deps.get` runs (#151).
  """

  alias Depdep.{Lock, Provider.Git}

  @prefix "src/v1"

  @doc "The prefix every source object lives under, for listing and reclamation."
  def prefix, do: @prefix

  @doc """
  The locked commit, which is this unit's whole identity.

  `{:ok, commit}` for a git entry, `:not_git` for anything else — a hex dependency's
  source is a tarball Mix fetches by checksum and is not this provider's business.
  """
  def commit(entry) when elem(entry, 0) == :git, do: {:ok, Lock.inner_checksum(entry)}
  def commit(_entry), do: :not_git

  @doc """
  Where a source object lives: `src/v1/<repository>/<commit>/source.tar.gz`.

  `:not_git` for a non-git entry. Readable rather than hashed, so a store can be
  browsed and a human can see which commit of which repository is held.
  """
  def object(entry) do
    with {:ok, commit} <- commit(entry) do
      {:ok, "#{@prefix}/#{Git.slug(Lock.repo(entry))}/#{commit}/source.tar.gz"}
    end
  end
end
