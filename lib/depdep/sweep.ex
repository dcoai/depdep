defmodule Depdep.Sweep do
  @moduledoc """
  Which objects reclamation may remove, and why.

  Pure: it is handed a listing, a live set and the clock, and answers what to
  delete. Everything that talks to a store stays in `Depdep.CLI`, so the rules
  here — the part worth being sure about — can be exercised without one.

  ## A wrong deletion is costly, never corrupting

  This is what justifies the whole approach, and most garbage collectors cannot
  say it. Delete something still needed and the next pipeline misses, recompiles
  and pushes it back. So the rules can be decided on cost rather than on fear,
  and an incomplete run degrades instead of breaking.

  ## One rule per prefix, because the providers are not alike

    * **`v2/` (mix)** — mark and sweep. Churn-driven growth, and the live set is
      exactly known from the roots consumers write.
    * **`git/v1/`** — epoch retention. A mirror is a seed whose staleness is
      harmless by construction, so an older epoch is *superseded* rather than
      unreachable. Age is the truer rule, and marking would keep every epoch any
      consumer ever pulled.
    * **`apt/v1/`** — untouched. Small, near-static, and shared across every
      consumer and image; its reachable set needs `apt-get --print-uris` in the
      right container to compute. Little to reclaim, more to get wrong.
    * **`roots/`** — age. They overwrite per consumer, ref and provider, so they
      accumulate only when a branch dies. Sweeping them keeps the thing that
      solves unbounded growth from growing unboundedly.
  """

  @doc """
  What to delete, as `{object, reason}`.

  `live` is every path named by a root written recently enough to count.
  `grace_days` protects anything just created: a consumer pushing while the
  listing was taken has written an object no root names yet, and deleting it
  would be a race, not a reclamation.
  """
  def plan(objects, live, opts) do
    grace_days = Keyword.get(opts, :grace_days, 2)
    window_days = Keyword.get(opts, :window_days, 30)
    keep_epochs = Keyword.get(opts, :keep_epochs, 2)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    settled = Enum.reject(objects, &newer_than?(&1, grace_days, now))

    settled
    |> Enum.flat_map(&verdict(&1, live, window_days, keep_epochs, now, epochs(settled)))
  end

  @doc "How many objects the grace period is protecting, for the report."
  def protected(objects, opts) do
    grace_days = Keyword.get(opts, :grace_days, 2)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    Enum.count(objects, &newer_than?(&1, grace_days, now))
  end

  defp verdict(object, live, window_days, keep_epochs, now, epochs) do
    cond do
      String.starts_with?(object.key, "apt/") ->
        []

      String.starts_with?(object.key, "roots/") ->
        if newer_than?(object, window_days, now),
          do: [],
          else: [{object, "a root nobody has refreshed in #{window_days} days"}]

      String.starts_with?(object.key, "git/") ->
        git_verdict(object, keep_epochs, epochs)

      true ->
        if MapSet.member?(live, object.key),
          do: [],
          else: [{object, "no current root references it"}]
    end
  end

  # Superseded rather than unreachable: keep the newest few epochs per
  # repository and drop the rest, whatever any root says.
  defp git_verdict(object, keep_epochs, epochs) do
    case parse_mirror(object.key) do
      {:ok, repo, epoch} ->
        kept = epochs |> Map.get(repo, []) |> Enum.sort(:desc) |> Enum.take(keep_epochs)
        if epoch in kept, do: [], else: [{object, "superseded mirror, keeping #{keep_epochs}"}]

      :error ->
        []
    end
  end

  defp epochs(objects) do
    objects
    |> Enum.flat_map(fn object ->
      case parse_mirror(object.key) do
        {:ok, repo, epoch} -> [{repo, epoch}]
        :error -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {repo, list} -> {repo, Enum.uniq(list)} end)
  end

  # `git/v1/<repo>/<epoch>/mirror.tar.gz`
  defp parse_mirror(key) do
    case String.split(key, "/") do
      ["git", "v1", repo, epoch | _] -> {:ok, repo, epoch}
      _ -> :error
    end
  end

  defp newer_than?(%{last_modified: stamp}, days, now) do
    case DateTime.from_iso8601(stamp) do
      # Unparseable means unknown age, and unknown age is treated as new — the
      # fail-safe direction, since the cost of keeping is disk and the cost of
      # deleting wrongly is a recompile.
      {:ok, at, _} -> DateTime.diff(now, at, :day) <= days
      _ -> true
    end
  end
end
