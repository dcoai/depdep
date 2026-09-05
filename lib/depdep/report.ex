defmodule Depdep.Report do
  @moduledoc """
  What happened to each dependency: which bucket it lands in, and how the
  tally reads at the end of a run.

  Separate from `Depdep.CLI` because this is the part worth testing and it
  needs no network. Whether a dependency can be keyed, and whether its trees
  are already on disk, decides its bucket before any request is made — only
  `:fetch` and `:offer` reach the store at all.

  **Each bucket names one event, and the buckets differ per direction.** They
  used to share a single `skipped` slot for three unrelated outcomes: a
  dependency that cannot be keyed, one already present locally, and one not
  built here. Those are not the same event. `cannot be keyed` is a LIMITATION
  the reader has to know about — a git dependency will never be cached, and it
  takes its dependents with it. The other two are NO-OPS, and the ordinary
  steady state of any warm tree. Merged, the number said nothing in the case
  where a reader most wants it: a developer with a populated `_build` got
  `skipped 555`, which the README then explained as "almost always one taken
  from a git remote" — which it was not.

  Every bucket is printed even at zero. `skipped 0` is the sentence "nothing in
  this project is unkeyable", and that is worth reading.
  """

  @buckets %{
    pull: [
      pulled: "pulled",
      missing: "missing",
      present: "already present",
      skipped: "skipped"
    ],
    push: [
      stored: "already stored",
      uploaded: "uploaded",
      not_built: "not built here",
      skipped: "skipped"
    ]
  }

  @doc "The buckets for a direction, in report order, as `{bucket, label}`."
  def buckets(direction), do: Map.fetch!(@buckets, direction)

  @doc """
  Where a dependency lands, before any network call.

  `{:done, bucket}` is a final answer. `{:network, :fetch | :offer}` is the only
  outcome that touches the store, and the caller turns it into a bucket from
  what the store says.
  """
  def outcome(_direction, {:skip, _reason}, _complete?), do: {:done, :skipped}
  def outcome(:pull, {:key, _hash}, true), do: {:done, :present}
  def outcome(:pull, {:key, _hash}, false), do: {:network, :fetch}
  def outcome(:push, {:key, _hash}, false), do: {:done, :not_built}
  def outcome(:push, {:key, _hash}, true), do: {:network, :offer}

  @doc """
  Adds one to a bucket.

  Raises on a bucket that is not part of this direction, rather than counting
  into a slot `render/2` will never print. A miscounted dependency would
  otherwise vanish silently, which is the failure this module exists to end.
  """
  def count(tally, direction, bucket) do
    if Keyword.has_key?(buckets(direction), bucket) do
      Map.update(tally, bucket, 1, &(&1 + 1))
    else
      raise ArgumentError, "#{inspect(bucket)} is not a #{direction} bucket"
    end
  end

  @doc "Combines the per-project tallies of one run."
  def merge(tallies) do
    Enum.reduce(tallies, %{}, fn tally, acc ->
      Map.merge(acc, tally, fn _bucket, a, b -> a + b end)
    end)
  end

  @doc "How many dependencies a tally accounts for."
  def total(tally), do: tally |> Map.values() |> Enum.sum()

  @doc "The summary line, every bucket named and none omitted at zero."
  def render(direction, tally) do
    direction
    |> buckets()
    |> Enum.map_join(", ", fn {bucket, label} -> "#{label} #{Map.get(tally, bucket, 0)}" end)
  end
end
