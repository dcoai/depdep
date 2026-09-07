defmodule Depdep.CLI do
  @moduledoc """
  The command line: `--plan`, `--pull`, `--push`.

  Invoked from a consumer's bootstrap script, which is how depdep runs before
  `mix deps.get` without being a dependency of the project it is serving:

      Mix.install([{:depdep, git: "...", tag: "v0.2.0"}])
      Depdep.CLI.main(System.argv())

  **Nothing below names an artifact type.** What is being moved, how it is keyed
  and where it belongs on disk are all `Depdep.Provider`'s business; this module
  owns the store, the concurrency, the counting and the rule that no failure
  here may fail a build.
  """

  alias Depdep.{Provider, Report, Roots, Unit}

  @switches [
    plan: :boolean,
    report: :boolean,
    within: :integer,
    consumer: :string,
    ref: :string,
    pull: :boolean,
    push: :boolean,
    provider: :keep,
    project: :keep,
    exclude: :keep,
    env: :string,
    package: :keep,
    apt_cache_dir: :string,
    repo: :keep,
    git_mirror_dir: :string,
    help: :boolean
  ]

  def main(argv) do
    with {:ok, opts} <- parse(argv),
         {:ok, providers} <- Provider.resolve(Keyword.get_values(opts, :provider)) do
      run(providers, opts)
    else
      {:error, problems} ->
        problems |> List.wrap() |> Enum.each(&warn/1)
        warn("run with --help for the switches this version understands")
        System.halt(2)
    end
  end

  @doc """
  `{:ok, opts}`, or `{:error, messages}` for anything not understood.

  Separate from `main/1` because `main/1` halts, and a decision worth testing
  should not require ending the VM to observe.

  **A switch depdep does not understand is a usage error, and usage errors
  fail.** That is not a hole in "failure is not an error" — that promise is about
  reaching and using the STORE, where the worst case is that the tool does the
  work itself. Nothing has failed to be reached here; depdep has been asked for
  something it cannot do. Silently dropping it is how `dco-tek/metresis` #86 lost
  an afternoon: `--provider apt` against a tag that predated providers went into
  `invalid`, the mix provider ran instead, and it died evaluating
  `config/config.exs` — which reads as a config bug.

  What makes failing safe here is that **an unknown switch cannot arrive on its
  own.** Someone has to edit the invocation, so this can never break a pipeline
  that was working; it can only stop one that has just been changed, which is
  when being stopped is useful.
  """
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _rest, []} ->
        {:ok,
         Keyword.merge(opts,
           root: File.cwd!(),
           env: String.to_atom(opts[:env] || "test")
         )}

      {_opts, _rest, invalid} ->
        {:error, Enum.map(invalid, &problem/1)}
    end
  end

  # `OptionParser` reports an unknown switch and a badly-typed value the same
  # way — `{"--thing", nil}` — so the name has to be checked against the known
  # set. Saying which it is matters: a reader whose value is missing should not
  # go looking for a typo.
  defp problem({switch, _value}) do
    if switch in known_switches() do
      "#{switch} was given a value it cannot take"
    else
      "#{switch} is not a switch this version of depdep understands"
    end
  end

  defp known_switches,
    do: Enum.map(@switches, fn {name, _} -> "--" <> String.replace("#{name}", "_", "-") end)

  defp run(providers, opts) do
    cond do
      opts[:help] -> IO.puts(usage())
      opts[:plan] -> plan(providers, opts)
      opts[:report] -> report(opts)
      opts[:pull] -> transfer(providers, opts, :pull)
      opts[:push] -> transfer(providers, opts, :push)
      true -> IO.puts(usage())
    end
  end

  defp plan(providers, opts) do
    # A plan shows what a pull would do; there is no third direction.
    opts = Keyword.put(opts, :direction, :pull)

    Enum.each(providers, fn provider ->
      {:ok, units, warnings} = provider.enumerate(opts)
      Enum.each(warnings, &warn/1)

      Enum.each(units, fn unit ->
        IO.puts([columns(unit), "\t", plan_key(unit.resolution)])
      end)
    end)
  end

  defp columns(%Unit{group: nil} = unit), do: [unit.name, "\t", unit.detail]
  defp columns(unit), do: [unit.group, "\t", unit.name, "\t", unit.detail]

  defp plan_key({:key, hash}), do: hash
  defp plan_key({:skip, reason}), do: "SKIP #{reason}"

  # The store is a cache. Every path out of this function that is not a hit ends
  # in "the tool does the work itself", which is why none of them are errors.
  defp transfer(providers, opts, direction) do
    case Depdep.S3.config() do
      {:error, reason} ->
        warn("store not configured (#{reason}) — skipping #{direction}, nothing will break")
        :ok

      {:ok, cfg} ->
        Depdep.S3.start()

        # `:direction` because what a provider wants moved can differ by
        # direction: `Depdep.Provider.Apt` asks apt what it WILL fetch on a pull
        # and asks the archives directory what WAS fetched on a push, and those
        # are genuinely different questions.
        opts = Keyword.put(opts, :direction, direction)

        tallies = Enum.map(providers, &transfer_provider(&1, opts, direction, cfg))
        IO.puts("depdep: " <> Report.render(direction, Report.merge(tallies)))
    end
  end

  defp transfer_provider(provider, opts, direction, cfg) do
    {:ok, units, warnings} = provider.enumerate(opts)
    Enum.each(warnings, &warn/1)
    if direction == :pull, do: record_root(provider, units, opts, cfg)

    # `timeout: :infinity` is deliberate and is NOT "no timeout". `Depdep.S3`
    # gives `:httpc` a 15 s connect and 300 s request timeout, so a stuck
    # transfer comes back as `{:error, _}` — attributable to its unit, reported
    # with a reason, and counted in the right bucket. A timeout at the stream
    # level would surface as `{:exit, :timeout}` carrying no identity, and the
    # run could name neither the unit nor the cause. Enforce it where the
    # identity still exists.
    #
    # A crash inside a step still takes the run down, exactly as it did when
    # this was an `Enum.reduce`. That is not an oversight: a provider reading a
    # file depdep itself just wrote and failing is a broken machine, not a cold
    # cache.
    units
    |> Task.async_stream(&step(provider, &1, direction, cfg),
      max_concurrency: Depdep.S3.concurrency(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, bucket}, tally ->
      Report.count(tally, direction, bucket)
    end)
  end

  # `Depdep.Report.outcome/3` decides everything that can be decided without the
  # network, and only `:fetch` and `:offer` reach the store at all.
  #
  # Returns the bucket this unit lands in rather than a tally: results are folded
  # as they arrive from the stream, so a step must not carry one.
  defp step(provider, unit, direction, cfg) do
    case Report.outcome(direction, unit.resolution, provider.present?(unit)) do
      {:done, :skipped} ->
        {:skip, reason} = unit.resolution
        warn("#{Unit.label(unit)}: skipped — #{reason}")
        :skipped

      {:done, bucket} ->
        bucket

      {:network, action} ->
        reach(action, provider, unit, cfg)
    end
  end

  defp reach(:fetch, provider, unit, cfg) do
    tmp = tmp_path()

    result =
      case Depdep.S3.get(cfg, unit.object, tmp) do
        :ok -> provider.restore(unit, tmp)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        record(provider, unit)
        :pulled

      {:error, "not found"} ->
        :missing

      {:error, reason} ->
        warn("#{Unit.label(unit)}: pull failed (#{reason}) — it will be built as usual")
        :missing
    end
  end

  defp reach(:offer, provider, unit, cfg) do
    case Depdep.S3.head(cfg, unit.object) do
      # A hit is the steady state, and it is exactly when the local tree is known
      # to match the key — so it must be noted here too. Noting only uploads
      # would leave a warm tree unrecognised and re-pulled on the next run.
      :hit ->
        record(provider, unit)
        :stored

      :miss ->
        upload(provider, unit, cfg)

      {:error, reason} ->
        warn("#{Unit.label(unit)}: HEAD failed (#{reason}) — not uploading")
        :skipped
    end
  end

  defp upload(provider, unit, cfg) do
    tmp = tmp_path()

    result =
      case provider.collect(unit, tmp) do
        :ok -> Depdep.S3.put(cfg, unit.object, tmp)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        record(provider, unit)
        :uploaded

      {:error, reason} ->
        warn("#{Unit.label(unit)}: upload failed (#{reason}) — the store simply stays cold")
        :skipped
    end
  end

  # Written before any transfer: the paths are known once units are enumerated,
  # and a transfer that then fails does not make them less wanted. See
  # `Depdep.Roots` for why this happens on pull rather than push.
  defp record_root(provider, units, opts, cfg) do
    {consumer, ref} = Roots.identity(opts, Keyword.fetch!(opts, :root))
    object = Roots.path(consumer, ref, Provider.name(provider))
    paths = units |> Enum.map(& &1.object) |> Enum.reject(&is_nil/1)

    tmp = tmp_path()
    File.write!(tmp, Roots.encode(paths))
    result = Depdep.S3.put(cfg, object, tmp)
    File.rm(tmp)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        warn(
          "could not record what #{consumer}/#{ref} needs (#{reason}) — " <>
            "reclamation may treat these objects as unreachable"
        )
    end
  end

  # Read-only, and deliberately needs no delete permission: it must be safe to
  # run with the credentials a pipeline holds.
  defp report(opts) do
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

  defp render_report(cfg, objects, within) do
    {roots, stored} = Enum.split_with(objects, &String.starts_with?(&1.key, Roots.prefix()))
    {fresh, stale} = Enum.split_with(roots, &within?(&1, within))
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

  defp within?(%{last_modified: stamp}, days) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at, :day) <= days
      _ -> false
    end
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

  # Bookkeeping: a note that cannot be written is reported and otherwise ignored.
  # Losing one costs a redundant pull next run; failing the build over it would
  # cost far more.
  defp record(provider, unit) do
    case provider.record(unit) do
      :ok ->
        :ok

      {:error, reason} ->
        warn("#{Unit.label(unit)}: could not note the key (#{reason}) — it will be pulled again")
    end
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "depdep-#{:erlang.unique_integer([:positive])}.tar.gz")

  defp warn(message), do: IO.puts(:stderr, "depdep: #{message}")

  defp usage do
    """
    Depdep — a content-addressed store for build artifacts.

      --plan     computed keys, no network
      --report   what the store holds, and how much of it is still reachable
      --pull     restore what the store has
      --push     upload what it does not

      --provider NAME operate on this artifact kind (repeatable).
                      Default: mix. Known: #{Provider.known()}

    Options for the mix provider:

      --project DIR   operate on this project (repeatable). Default: the current
                      directory if it holds a mix.exs, otherwise every mix.exs
                      beneath it.
      --exclude PREFIX drop a member and everything beneath it (repeatable),
                      matched on whole path segments
      --env ENV       MIX_ENV to operate on (default test)

    Options for --report:

      --within DAYS   treat a root written within this many days as current
                      (default 30)

    Options for --pull, which records what this consumer needs:

      --consumer NAME who is pulling (default: $CI_PROJECT_PATH, else the
                      checkout qualified by host)
      --ref NAME      which branch (default: $CI_COMMIT_REF_SLUG)

    Options for the apt provider:

      --package NAME      a package the job will install (repeatable). Needed
                          for --pull; --push reads the archives directory.
      --apt-cache-dir DIR where apt keeps downloaded packages
                          (default /var/cache/apt/archives)

    Options for the git provider:

      --repo URL           a repository to mirror (repeatable)
      --git-mirror-dir DIR where mirrors are kept (default .depdep/git)

    Reads DEPDEP_ENDPOINT, DEPDEP_BUCKET, DEPDEP_ACCESS_KEY, DEPDEP_SECRET_KEY
    and optionally DEPDEP_REGION. With any of them unset, --pull and --push
    report why and do nothing.
    """
  end
end
