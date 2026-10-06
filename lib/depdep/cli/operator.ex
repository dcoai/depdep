defmodule Depdep.CLI.Operator do
  @moduledoc """
  The two commands a person runs against the store, never a pipeline:
  `--report` and `--sweep`.

  Split from `Depdep.CLI` by size alone — the transfer path grew its second
  pass and its compile step (#64, #65) and the file was nearing a thousand
  lines. Nothing here changed in the move. Both commands read the whole
  bucket and the roots `--pull` writes; `--sweep` is the only thing in depdep
  that deletes, and it is guarded by the credential rather than a flag: a
  pipeline identity holds Get and Put and not Delete.
  """

  alias Depdep.{Roots, Sweep}

  # Read-only, and deliberately needs no delete permission: it must be safe to
  # run with the credentials a pipeline holds.
  def report(opts) do
    case Depdep.S3.config() do
      {:error, reason} ->
        warn("store not configured (#{reason}) — nothing to report")

      {:ok, cfg} ->
        Depdep.S3.start()
        within = Keyword.get(opts, :within, 30)

        case Depdep.S3.list(cfg) do
          {:ok, objects} -> render_report(cfg, objects, within)
          {:error, reason} -> warn("could not list the store (#{reason})")
        end
    end
  end

  # Operator-run. A pipeline identity has Get and Put and not Delete, so a sweep
  # with CI credentials fails on permissions — the guard is the credential, not
  # this flag.
  def sweep(opts) do
    case Depdep.S3.config() do
      {:error, reason} ->
        warn("store not configured (#{reason}) — nothing to sweep")

      {:ok, cfg} ->
        case aimed_at(cfg, opts) do
          :ok ->
            Depdep.S3.start()

            case Depdep.S3.list(cfg) do
              {:ok, objects} -> sweep_objects(cfg, objects, opts)
              {:error, reason} -> warn("could not list the store (#{reason})")
            end

          {:error, reason} ->
            warn(reason <> " — refusing to sweep")
        end
    end
  end

  # The fourth rail (#150): `--confirm` must name the bucket it is about to change,
  # and the name must be this store's.
  #
  # The other three rails guard against acting by accident (`--confirm`), against
  # the clock (`--grace`) and against an empty live set (`current_roots`). None asks
  # *which* store, and the answer can arrive from an inherited environment variable
  # — which is how the group's credentials reached depdep's own CI in #148. The
  # credential remains the real guard: a pipeline identity cannot delete at all
  # (measured, 403). This is for the operator who legitimately can.
  #
  # Checked before the listing, so a misaimed invocation costs nothing and says so
  # immediately rather than after a thousand objects have been enumerated.
  defp aimed_at(cfg, opts) do
    named = Keyword.get(opts, :bucket)

    cond do
      # `Depdep.CLI.combination/2` rejects `--confirm` without `--bucket`, so a nil
      # here is only reachable for a dry run, which changes nothing.
      is_nil(named) ->
        :ok

      named == cfg.bucket ->
        :ok

      true ->
        {:error, ~s(--bucket says "#{named}" but the store configured here is "#{cfg.bucket}")}
    end
  end

  defp sweep_objects(cfg, objects, opts) do
    within = Keyword.get(opts, :within, 30)

    # The decision itself lives in `Depdep.Sweep.current_roots/2`, beside the
    # other sweep rules and testable without a store (#126). This branch is only
    # what to say about it.
    case Sweep.current_roots(objects, window_days: within) do
      {:refuse, reason} ->
        warn(reason <> " — refusing to sweep")
        warn("run --report first; if consumers really have stopped, widen --within")

      {:ok, fresh} ->
        live = reachable_set(cfg, fresh)

        rules = [
          grace_days: Keyword.get(opts, :grace, 2),
          window_days: within,
          keep_epochs: Keyword.get(opts, :keep_epochs, 2)
        ]

        doomed = Sweep.plan(objects, live, rules)
        protected = Sweep.protected(objects, rules)

        IO.puts(
          "depdep: #{length(objects)} objects, #{length(fresh)} current roots, " <>
            "#{protected} within the #{rules[:grace_days]}-day grace period"
        )

        Enum.each(doomed, fn {object, reason} ->
          IO.puts(
            "depdep: #{if opts[:confirm], do: "delete", else: "would delete"} #{object.key} — #{reason}"
          )
        end)

        if opts[:confirm], do: delete_all(cfg, doomed), else: dry_run_summary(doomed)
    end
  end

  defp dry_run_summary(doomed) do
    IO.puts(
      "depdep: #{length(doomed)} objects would be removed, #{mib(Enum.map(doomed, &elem(&1, 0)))} — " <>
        "re-run with --confirm to remove them"
    )
  end

  defp delete_all(cfg, doomed) do
    removed =
      Enum.count(doomed, fn {object, _reason} ->
        case Depdep.S3.delete(cfg, object.key) do
          :ok ->
            true

          {:error, reason} ->
            warn("#{object.key}: delete failed (#{reason}) — leaving it")
            false
        end
      end)

    IO.puts("depdep: removed #{removed} of #{length(doomed)} objects")
  end

  defp render_report(cfg, objects, within) do
    {roots, stored} = Enum.split_with(objects, &String.starts_with?(&1.key, Roots.prefix()))

    # The same rule `--sweep` uses (#126). Two definitions of "a current root"
    # would let the report an operator checks before deleting disagree with the
    # delete, which is the one disagreement that must not exist here.
    fresh =
      case Sweep.current_roots(objects, window_days: within) do
        {:ok, fresh} -> fresh
        {:refuse, _} -> []
      end

    stale = roots -- fresh
    reachable = reachable_set(cfg, fresh)

    IO.puts("depdep: #{length(roots)} roots, #{length(fresh)} written in the last #{within} days")

    if stale != [] do
      IO.puts(
        "depdep: #{length(stale)} roots older than that are ignored — their consumers have not built"
      )
    end

    stored
    |> Enum.group_by(&group(&1.key))
    |> Enum.sort()
    |> Enum.each(fn {group, group_objects} ->
      {live, dead} = Enum.split_with(group_objects, &MapSet.member?(reachable, &1.key))

      IO.puts(
        "depdep: #{group}\t#{length(group_objects)} objects, #{mib(group_objects)} — " <>
          "#{length(live)} reachable, #{length(dead)} not (#{mib(dead)})"
      )
    end)
  end

  # Every path a fresh root names. A root that cannot be read is reported and
  # skipped: one malformed root must not make a whole store look unreachable.
  defp reachable_set(cfg, roots) do
    Enum.reduce(roots, MapSet.new(), fn root, acc ->
      tmp = tmp_path()
      result = Depdep.S3.get(cfg, root.key, tmp)

      paths =
        with :ok <- result,
             {:ok, contents} <- File.read(tmp),
             {:ok, paths} <- Roots.decode(contents) do
          paths
        else
          {:error, reason} ->
            warn("#{root.key}: unreadable root (#{inspect(reason)}) — ignoring it")
            []
        end

      File.rm(tmp)
      Enum.into(paths, acc)
    end)
  end

  # Object paths are readable by design — `v2/...`, `apt/v1/...`, `git/v1/...` —
  # so the leading segments are the natural grouping.
  defp group(key) do
    case String.split(key, "/") do
      ["v2" | _] -> "v2"
      [provider, version | _] -> "#{provider}/#{version}"
      [other | _] -> other
    end
  end

  defp mib(objects) do
    bytes = objects |> Enum.map(&(&1.size || 0)) |> Enum.sum()
    "#{Float.round(bytes / 1_048_576, 1)} MiB"
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "depdep-#{:erlang.unique_integer([:positive])}.tar.gz")

  defp warn(message), do: IO.puts(:stderr, "depdep: #{message}")
end
