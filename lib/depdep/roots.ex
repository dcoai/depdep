defmodule Depdep.Roots do
  @moduledoc """
  What each consumer says it still needs.

  A root is a small object listing the object paths one consumer wanted on one
  `--pull`. The sweep keeps whatever the recent roots reference and may reclaim
  the rest.

  ## Why roots rather than checkouts

  The obvious alternative is for an operator to run `--plan` across every
  consumer and union the result. That fails in two ways. It requires holding
  every consumer at the right ref and reproducing each one's exact invocation —
  which `--env`, which `--exclude`, which providers — and getting any of it
  wrong shortens the live set, which means over-deletion. And **it cannot see
  branches**: a release branch built quarterly has a live set that exists in no
  checkout the operator happens to hold.

  A root is produced by the thing that actually knows the answer, at the moment
  it knows it. Nothing to gather and nothing to reproduce.

  ## It is also the last-access policy, one layer up

  Neither MinIO nor S3 can expire on last access — both compute expiry from
  creation date. But a consumer that builds refreshes its roots, and one that
  has not built in N days ages out of them and its objects become reclaimable.
  That is "nothing has read this in N days", expressed where we can express it.

  ## Written on pull, not push

  `--pull` is what says "this consumer needs these". `--push` happens only when
  a build succeeds, and a failing pipeline's dependencies are no less needed.
  """

  @prefix "roots"
  @format "depdep-roots/1"

  @doc """
  Where one consumer's root for one provider lives.

  Keyed by consumer, ref AND provider: a consumer that runs `--pull --provider
  mix` and `--pull --provider apt` separately must not have the second overwrite
  the first.
  """
  def path(consumer, ref, provider),
    do: "#{@prefix}/#{slug(consumer)}/#{slug(ref)}/#{slug(provider)}"

  @doc "The prefix every root lives under, for listing."
  def prefix, do: @prefix <> "/"

  @doc "Serialises object paths. A version line first, so the format can change."
  def encode(object_paths), do: Enum.join([@format | Enum.sort(object_paths)], "\n") <> "\n"

  @doc """
  Reads a root back, or `{:error, reason}`.

  An unreadable or unrecognised root is an error the caller reports and skips —
  never something that stops a run, because one malformed root must not make a
  whole store look unreachable.
  """
  def decode(contents) do
    case String.split(contents, "\n", trim: true) do
      [@format | paths] -> {:ok, paths}
      [other | _] -> {:error, "unrecognised root format #{inspect(String.slice(other, 0, 40))}"}
      [] -> {:error, "empty root"}
    end
  end

  @doc """
  Who this consumer is, from the environment.

  CI names itself; outside CI the checkout does, qualified by host so two
  developers do not share one root and quietly halve each other's live set.
  """
  def identity(opts, root) do
    consumer =
      Keyword.get(opts, :consumer) || System.get_env("CI_PROJECT_PATH") ||
        "local-#{hostname()}-#{Path.basename(Path.expand(root))}"

    ref = Keyword.get(opts, :ref) || System.get_env("CI_COMMIT_REF_SLUG") || "unknown"

    {consumer, ref}
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  # Object paths are readable by design, so keep these readable too.
  defp slug(value) do
    value
    |> to_string()
    |> String.replace(~r{[^A-Za-z0-9._-]+}, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      slug -> slug
    end
  end
end
