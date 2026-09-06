defmodule Depdep.CLI do
  @moduledoc """
  The command line: `--plan`, `--pull`, `--push`.

  Invoked from a consumer's bootstrap script, which is how depdep runs before
  `mix deps.get` without being a dependency of the project it is serving:

      Mix.install([{:depdep, git: "...", tag: "v0.1.0"}])
      Depdep.CLI.main(System.argv())
  """

  alias Depdep.Report

  @switches [
    plan: :boolean,
    pull: :boolean,
    push: :boolean,
    project: :keep,
    exclude: :keep,
    env: :string,
    help: :boolean
  ]

  def main(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)
    env = String.to_atom(opts[:env] || "test")
    root = File.cwd!()
    projects = Depdep.Layout.projects(root, opts)

    cond do
      opts[:help] -> IO.puts(usage())
      opts[:plan] -> plan(root, projects, env)
      opts[:pull] -> transfer(root, projects, env, :pull)
      opts[:push] -> transfer(root, projects, env, :push)
      true -> IO.puts(usage())
    end
  end

  defp plan(root, projects, env) do
    Enum.each(projects, fn project ->
      case Depdep.keys_for(root, project, env) do
        {:ok, keys, lock} ->
          keys
          |> Enum.sort()
          |> Enum.each(fn
            {name, {:key, hash}} ->
              IO.puts(
                "#{project}\t#{name}\t#{Depdep.Lock.version(Map.fetch!(lock, name))}\t#{hash}"
              )

            {name, {:skip, reason}} ->
              IO.puts("#{project}\t#{name}\t-\tSKIP #{reason}")
          end)

        {:error, reason} ->
          warn("#{project}: #{reason} — every dependency will be compiled")
      end
    end)
  end

  # The store is a cache. Every path out of this function that is not a hit ends
  # in "Mix will compile it", which is why none of them are errors.
  defp transfer(root, projects, env, direction) do
    case Depdep.S3.config() do
      {:error, reason} ->
        warn("store not configured (#{reason}) — skipping #{direction}, nothing will break")
        :ok

      {:ok, cfg} ->
        Depdep.S3.start()
        tallies = Enum.map(projects, &transfer_project(root, &1, env, direction, cfg))
        IO.puts("depdep: " <> Report.render(direction, Report.merge(tallies)))
    end
  end

  defp transfer_project(root, project, env, direction, cfg) do
    case Depdep.keys_for(root, project, env) do
      {:error, reason} ->
        warn("#{project}: #{reason} — every dependency will be compiled")
        %{}

      {:ok, keys, lock} ->
        project_dir = Path.join(root, project)

        # `timeout: :infinity` is deliberate and is NOT "no timeout". `Depdep.S3`
        # gives `:httpc` a 15 s connect and 300 s request timeout, so a stuck
        # transfer comes back as `{:error, _}` — attributable to its dependency,
        # reported with a reason, and counted in the right bucket. A timeout at
        # the stream level would surface as `{:exit, :timeout}` carrying no
        # identity, and the run could name neither the dependency nor the cause.
        # Enforce it where the identity still exists.
        #
        # A crash inside a step still takes the run down, exactly as it did when
        # this was an `Enum.reduce`. That is not an oversight: `Depdep.S3.put/3`
        # reads a file depdep itself just wrote, and a failure there is a broken
        # machine, not a cold cache.
        keys
        |> Enum.sort()
        |> Task.async_stream(
          fn entry -> step(entry, project, lock, project_dir, env, direction, cfg) end,
          max_concurrency: Depdep.S3.concurrency(),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce(%{}, fn {:ok, bucket}, tally ->
          Report.count(tally, direction, bucket)
        end)
    end
  end

  # `Depdep.Report.outcome/3` decides everything that can be decided without the
  # network, and only `:fetch` and `:offer` reach the store at all.
  #
  # Returns the bucket this dependency lands in rather than a tally: results are
  # folded as they arrive from the stream, so a step must not carry one.
  defp step({name, resolution}, project, lock, project_dir, env, direction, cfg) do
    complete? = Depdep.Archive.complete?(project_dir, name, env)

    case Report.outcome(direction, resolution, complete?) do
      {:done, :skipped} ->
        {:skip, reason} = resolution
        warn("#{project}/#{name}: skipped — #{reason}")
        :skipped

      {:done, bucket} ->
        bucket

      {:network, action} ->
        {:key, hash} = resolution
        object = Depdep.Key.object(name, Map.fetch!(lock, name), hash)
        reach(action, cfg, object, project_dir, env, project, name)
    end
  end

  # Both trees, not just the build: a dependency with `_build` but no `deps`
  # would be treated as present, and Mix would then recompile it the moment
  # `mix deps.get` fetched the source. See `Depdep.Archive`.
  defp reach(:fetch, cfg, object, project_dir, _env, project, name) do
    tmp = tmp_path()

    result =
      case Depdep.S3.get(cfg, object, tmp) do
        :ok -> Depdep.Archive.extract(tmp, project_dir)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        :pulled

      {:error, "not found"} ->
        :missing

      {:error, reason} ->
        warn("#{project}/#{name}: pull failed (#{reason}) — Mix will compile it")
        :missing
    end
  end

  defp reach(:offer, cfg, object, project_dir, env, project, name) do
    case Depdep.S3.head(cfg, object) do
      :hit ->
        :stored

      :miss ->
        upload(cfg, object, project_dir, env, project, name)

      {:error, reason} ->
        warn("#{project}/#{name}: HEAD failed (#{reason}) — not uploading")
        :skipped
    end
  end

  defp upload(cfg, object, project_dir, env, project, name) do
    tmp = tmp_path()

    result =
      case Depdep.Archive.create(project_dir, name, env, tmp) do
        :ok -> Depdep.S3.put(cfg, object, tmp)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        :uploaded

      {:error, reason} ->
        warn("#{project}/#{name}: upload failed (#{reason}) — the store simply stays cold")
        :skipped
    end
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "depdep-#{:erlang.unique_integer([:positive])}.tar.gz")

  defp warn(message), do: IO.puts(:stderr, "depdep: #{message}")

  defp usage do
    """
    Dependency Depot — a content-addressed store for compiled dependencies.

      --plan     computed keys, no network
      --pull     restore what the store has
      --push     upload what it does not

      --project DIR   operate on this project (repeatable). Default: the current
                      directory if it holds a mix.exs, otherwise every mix.exs
                      beneath it.
      --exclude DIR   drop a top-level directory from discovery (repeatable)
      --env ENV       MIX_ENV to operate on (default test)

    Reads DEPDEP_ENDPOINT, DEPDEP_BUCKET, DEPDEP_ACCESS_KEY, DEPDEP_SECRET_KEY
    and optionally DEPDEP_REGION. With any of them unset, --pull and --push
    report why and do nothing.
    """
  end
end
