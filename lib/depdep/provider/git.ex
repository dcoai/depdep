defmodule Depdep.Provider.Git do
  @moduledoc """
  Bare mirrors of git repositories, so a clone is a local copy rather than a
  network transfer.

  Depdep stores a mirror; the consumer clones against it with
  `--reference`/`--dissociate`, which is the established way to turn a
  minutes-long clone of a large repository into a seconds-long one. As
  everywhere else here, depdep's responsibility ends at putting something on
  disk — it never clones your repository for you.

  ## A stale mirror is not a wrong answer

  This is the fact the whole design rests on, and it is the opposite of the Mix
  provider's situation. A wrong Mix object is a build that compiles clean,
  passes its tests, and is wrong — which is why `Depdep.Key` recurses over the
  entire input closure. A mirror is only a SEED: whatever it contains, the
  consumer's own fetch reconciles it against the real remote. An out-of-date
  mirror costs a larger delta and nothing else. There is no silent-wrong-answer
  failure mode to defend against.

  That is what makes the key cheap. Objects are keyed on the repository and a
  monthly **epoch** rather than on a commit:

      git/v1/<slug>/2026-09/mirror.tar.gz

  Each epoch object is written once and never modified, so the store stays
  append-only; storage is bounded by months rather than by commits; and the
  worst case is one cold clone per repository per month, which the following
  `--push` then stores for everyone else. Self-healing, with no bookkeeping.

  If a fast-moving repository ever makes the end-of-month delta expensive, a
  finer epoch is a change to `epoch/0` — a parameter, not a redesign.
  """

  @behaviour Depdep.Provider

  alias Depdep.Unit

  @prefix "git/v1"
  @default_dir ".depdep/git"

  @impl true
  def enumerate(opts) do
    dir = Keyword.get(opts, :git_mirror_dir, @default_dir)
    direction = Keyword.get(opts, :direction, :pull)

    case {Keyword.get_values(opts, :repo), System.find_executable("git")} do
      {[], _} ->
        {:ok, [], []}

      {_repos, nil} ->
        {:ok, [], ["git: no git on this machine — mirrors will not be used"]}

      {repos, _} ->
        {:ok, Enum.map(repos, &unit(&1, dir, direction)), []}
    end
  end

  defp unit(url, dir, direction) do
    slug = slug(url)

    %Unit{
      name: slug,
      detail: epoch(),
      resolution: {:key, epoch()},
      object: "#{@prefix}/#{slug}/#{epoch()}/mirror.tar.gz",
      context: %{url: url, slug: slug, dir: dir, direction: direction}
    }
  end

  @doc """
  The current epoch. Monthly — see the moduledoc for why coarse is fine here.
  """
  def epoch, do: Calendar.strftime(Date.utc_today(), "%Y-%m")

  @doc """
  A readable, unique directory name for a repository URL.

  Host and path rather than a hash, so the store and the mirror directory can
  both be read by a person. Scheme, credentials and the `.git` suffix are
  dropped so `https://host/x.git` and `git@host:x` name the same mirror — they
  are the same repository, and storing it twice would be a waste that is also a
  lie about what is cached.
  """
  def slug(url) do
    url
    |> String.replace(~r{^[a-z+]+://}, "")
    |> String.replace(~r{^[^/@]+@}, "")
    |> String.replace(":", "/")
    |> String.replace_suffix(".git", "")
    |> String.replace(~r{[^A-Za-z0-9._-]+}, "-")
    |> String.trim("-")
  end

  @doc "Where this repository's mirror lives on disk."
  def mirror_path(%Unit{context: %{dir: dir, slug: slug}}), do: Path.join(dir, "#{slug}.git")

  # On a PULL this is the ordinary question: is the mirror already here, in
  # which case there is nothing to fetch.
  #
  # On a PUSH it is a different question, and the answer is always yes: a mirror
  # is obtainable from the repository itself, so this provider can always offer
  # one. `collect/2` is what then produces it, and it only runs when the store
  # says it does not already have this epoch — so the clone happens once per
  # repository per month, not once per pipeline.
  @impl true
  def present?(%Unit{context: %{direction: :push}}), do: true

  def present?(%Unit{} = unit) do
    path = mirror_path(unit)
    File.dir?(path) and File.regular?(Path.join(path, "HEAD"))
  end

  @impl true
  def restore(%Unit{context: %{dir: dir, slug: slug}}, tmp) do
    File.mkdir_p!(dir)
    Depdep.Archive.extract(tmp, dir, ["#{slug}.git"])
  end

  # Nothing to note, for the reason the whole provider is built on: a stale
  # mirror is not a wrong answer. It is a seed the consumer's own fetch
  # reconciles against the real remote, so being out of date costs a larger
  # delta and nothing else — there is no staleness here worth detecting.
  @impl true
  def record(%Unit{}), do: :ok

  @impl true
  def collect(%Unit{} = unit, tmp) do
    with :ok <- ensure_mirror(unit) do
      Depdep.Archive.create_trees(
        unit.context.dir,
        ["#{unit.context.slug}.git"],
        tmp,
        unit.context.slug
      )
    end
  end

  # Clone if there is no mirror yet, otherwise bring the existing one up to date.
  # `--mirror` keeps every ref, which is what makes the result usable as a
  # `--reference` for any branch a consumer asks for.
  defp ensure_mirror(%Unit{context: %{url: url, dir: dir}} = unit) do
    path = mirror_path(unit)

    if present?(%{unit | context: %{unit.context | direction: :pull}}) do
      git(["--git-dir", path, "remote", "update", "--prune"])
    else
      File.mkdir_p!(dir)
      git(["clone", "--mirror", url, path])
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "git #{hd(args)} exited #{status}: #{summary(output)}"}
    end
  end

  defp summary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> Kernel.||("no output")
    |> String.slice(0, 200)
  end
end
