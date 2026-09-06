defmodule Depdep.CLI do
  @moduledoc """
  The command line: `--plan`, `--pull`, `--push`.

  Invoked from a consumer's bootstrap script, which is how depdep runs before
  `mix deps.get` without being a dependency of the project it is serving:

      Mix.install([{:depdep, git: "...", tag: "v0.1.0"}])
      Depdep.CLI.main(System.argv())

  **Nothing below names an artifact type.** What is being moved, how it is keyed
  and where it belongs on disk are all `Depdep.Provider`'s business; this module
  owns the store, the concurrency, the counting and the rule that no failure
  here may fail a build.
  """

  alias Depdep.{Provider, Report, Unit}

  @switches [
    plan: :boolean,
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
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    opts =
      Keyword.merge(opts,
        root: File.cwd!(),
        env: String.to_atom(opts[:env] || "test")
      )

    case Provider.resolve(Keyword.get_values(opts, :provider)) do
      {:error, reason} ->
        warn(reason)

      {:ok, providers} ->
        cond do
          opts[:help] -> IO.puts(usage())
          opts[:plan] -> plan(providers, opts)
          opts[:pull] -> transfer(providers, opts, :pull)
          opts[:push] -> transfer(providers, opts, :push)
          true -> IO.puts(usage())
        end
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
      :hit ->
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
        :uploaded

      {:error, reason} ->
        warn("#{Unit.label(unit)}: upload failed (#{reason}) — the store simply stays cold")
        :skipped
    end
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "depdep-#{:erlang.unique_integer([:positive])}.tar.gz")

  defp warn(message), do: IO.puts(:stderr, "depdep: #{message}")

  defp usage do
    """
    Depdep — a content-addressed store for build artifacts.

      --plan     computed keys, no network
      --pull     restore what the store has
      --push     upload what it does not

      --provider NAME operate on this artifact kind (repeatable).
                      Default: mix. Known: #{Provider.known()}

    Options for the mix provider:

      --project DIR   operate on this project (repeatable). Default: the current
                      directory if it holds a mix.exs, otherwise every mix.exs
                      beneath it.
      --exclude DIR   drop a top-level directory from discovery (repeatable)
      --env ENV       MIX_ENV to operate on (default test)

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
