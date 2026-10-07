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

    * **the schema prefix (mix), and `src/v1/`** — mark and sweep. Churn-driven
      growth, and the live set is exactly known from the roots consumers write.
      Named by `rule_for/1` as the *fall-through* rather than by any particular
      schema spelling, which is why the `v2` → `v3` bump did not break
      reclamation. A source checkout is decided the same way, deliberately: it
      is named by the roots exactly as a build is (#165).
    * **a retired schema** — removed without consulting the live set at all.
      Nothing depdep runs can request one (`Depdep.Key.retired/0`, #166).
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

  @doc """
  The roots that count as current, or a refusal — the third rail
  (`spec/08-reclamation.md#rails`).

  **A store nobody uses and a misconfigured invocation look identical from the
  outside**, and one of them would have reclamation delete everything. So the
  absence of any current root is a refusal rather than an empty live set.

  Pure, and here rather than in `Depdep.CLI.Operator`, because this is the rail
  whose failure is unbounded and it was the one with no test (#126). The other
  two rails guard against the clock and against a slip of the hand; this one
  guards against the operator being wrong.

  `{:ok, roots}` or `{:refuse, reason}`. An unparseable timestamp counts as
  **current**, the same fail-safe direction `verdict/6` takes and the one
  `spec/08-reclamation.md#prefixes` states: an unreadable age must not silently
  shrink the live set, because a shrunken live set means over-deletion. The
  private helper this replaced in `Depdep.CLI.Operator` treated it as stale,
  which contradicted both.
  """
  def current_roots(objects, opts \\ []) do
    within = Keyword.get(opts, :window_days, 30)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    fresh =
      objects
      |> Enum.filter(&String.starts_with?(&1.key, Depdep.Roots.prefix()))
      |> Enum.filter(&newer_than?(&1, within, now))

    case fresh do
      [] -> {:refuse, "no root has been written in the last #{within} days"}
      fresh -> {:ok, fresh}
    end
  end

  @doc "How many objects the grace period is protecting, for the report."
  def protected(objects, opts) do
    grace_days = Keyword.get(opts, :grace_days, 2)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    Enum.count(objects, &newer_than?(&1, grace_days, now))
  end

  @doc """
  Which rule a key falls under: `:retired`, `:apt`, `:roots`, `:git`, `:source` or `:mix`.

  **`:mix` is the fall-through**, and that is the whole point of exposing this. The mix
  prefix is "not one of the named providers" rather than any particular spelling, so a
  schema bump cannot move an object out of it — which is why a schema bump did not break
  reclamation when `v2` became `v3`, and why it cannot break the report either (#169, for
  #125). `Depdep.CLI.Operator` groups by this, so the report an operator reads before
  deleting and the delete itself classify every key with one function rather than two that
  agree by coincidence.
  """
  def rule_for(key) do
    cond do
      # **A retired schema's objects are unreachable by construction** (#166, for #140).
      # `Depdep.Key.object/3` builds every path from the CURRENT schema, so nothing
      # depdep runs will ever ask for one of these — the live set cannot change the
      # answer, and a root that still names one was written by a version nobody runs.
      #
      # Checked first, before the `:mix` fall-through would hand it to the live set.
      retired?(key) -> :retired
      String.starts_with?(key, "apt/") -> :apt
      String.starts_with?(key, "roots/") -> :roots
      String.starts_with?(key, "git/") -> :git
      String.starts_with?(key, Depdep.Provider.Mix.Source.prefix() <> "/") -> :source
      true -> :mix
    end
  end

  defp verdict(object, live, window_days, keep_epochs, now, epochs) do
    case rule_for(object.key) do
      # The grace window still applies to a retired object: `plan/3` has already rejected
      # anything newer, because the race a push can lose to a listing does not care which
      # schema it is.
      :retired ->
        [{object, "schema #{schema_of(object.key)} is retired"}]

      :apt ->
        []

      :roots ->
        if newer_than?(object, window_days, now),
          do: [],
          else: [{object, "a root nobody has refreshed in #{window_days} days"}]

      :git ->
        git_verdict(object, keep_epochs, epochs)

      # **Source and mix are decided identically, and that is a decision rather than an
      # absence of one** (#165). A source object is named by the roots a consumer writes
      # exactly as a build is, so reachability is the truer rule — unlike a git mirror,
      # whose staleness is harmless and so is kept by epoch. Named separately from `:mix`
      # because the report groups by this and `src/v1` is not a schema (#169).
      rule when rule in [:mix, :source] ->
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

  defp retired?(key), do: schema_of(key) in Depdep.Key.retired()

  defp schema_of(key), do: key |> String.split("/", parts: 2) |> hd()

  # "Within N days" means **strictly less than** N days old (#170, for #108).
  #
  # It was `<=`, and that made `--grace 0` protect everything rather than nothing:
  # `DateTime.diff/3` truncates to whole days, so an object written moments ago is 0 days
  # old, and 0 was inside a 0-day window. The only value that protected nothing was `-1`,
  # which depdep's own CI job had to pass with a paragraph explaining the minus sign.
  #
  # **Truncation stops mattering once the comparison is strict**, which is worth saying
  # because it is not obvious: for an integer `d`, `floor(x) < d` is equivalent to `x < d`.
  # So this is exactly a strict comparison in seconds — there is no residual fraction of a
  # day, and no reason to change units to get an exact boundary.
  #
  # Asked by four callers — `--grace` twice (`plan/3`, `protected/2`) and `--within` twice
  # (`current_roots/2`, the roots rule in `verdict/6`) — so one rule rather than a
  # comparison chosen per caller. `<=` was the fail-safe direction at all four, and the
  # protection that matters is the 2-day default, `--confirm`, `--bucket`, the
  # no-current-roots refusal and the credential, not an off-by-one in a truncated day count.
  defp newer_than?(%{last_modified: stamp}, days, now) do
    case DateTime.from_iso8601(stamp) do
      # Unparseable means unknown age, and unknown age is treated as new — the
      # fail-safe direction, since the cost of keeping is disk and the cost of
      # deleting wrongly is a recompile.
      {:ok, at, _} -> DateTime.diff(now, at, :day) < days
      _ -> true
    end
  end
end
