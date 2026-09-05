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

        keys
        |> Enum.sort()
        |> Enum.reduce(%{}, fn entry, tally ->
          step(entry, project, lock, project_dir, env, direction, cfg, tally)
        end)
    end
  end

  # `Depdep.Report.outcome/3` decides everything that can be decided without the
  # network, and only `:fetch` and `:offer` reach the store at all.
  defp step({name, resolution}, project, lock, project_dir, env, direction, cfg, tally) do
    complete? = Depdep.Archive.complete?(project_dir, name, env)

    case Report.outcome(direction, resolution, complete?) do
      {:done, :skipped} ->
        {:skip, reason} = resolution
        warn("#{project}/#{name}: skipped — #{reason}")
        Report.count(tally, direction, :skipped)

      {:done, bucket} ->
        Report.count(tally, direction, bucket)

      {:network, action} ->
        {:key, hash} = resolution
        object = Depdep.Key.object(name, Map.fetch!(lock, name), hash)
        reach(action, cfg, object, project_dir, env, project, name, tally)
    end
  end

  # Both trees, not just the build: a dependency with `_build` but no `deps`
  # would be treated as present, and Mix would then recompile it the moment
  # `mix deps.get` fetched the source. See `Depdep.Archive`.
  defp reach(:fetch, cfg, object, project_dir, _env, project, name, tally) do
    tmp = tmp_path()

    result =
      case Depdep.S3.get(cfg, object, tmp) do
        :ok -> Depdep.Archive.extract(tmp, project_dir)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        Report.count(tally, :pull, :pulled)

      {:error, "not found"} ->
        Report.count(tally, :pull, :missing)

      {:error, reason} ->
        warn("#{project}/#{name}: pull failed (#{reason}) — Mix will compile it")
        Report.count(tally, :pull, :missing)
    end
  end

  defp reach(:offer, cfg, object, project_dir, env, project, name, tally) do
    case Depdep.S3.head(cfg, object) do
      :hit ->
        Report.count(tally, :push, :stored)

      :miss ->
        upload(cfg, object, project_dir, env, project, name, tally)

      {:error, reason} ->
        warn("#{project}/#{name}: HEAD failed (#{reason}) — not uploading")
        Report.count(tally, :push, :skipped)
    end
  end

  defp upload(cfg, object, project_dir, env, project, name, tally) do
    tmp = tmp_path()

    result =
      case Depdep.Archive.create(project_dir, name, env, tmp) do
        :ok -> Depdep.S3.put(cfg, object, tmp)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        Report.count(tally, :push, :uploaded)

      {:error, reason} ->
        warn("#{project}/#{name}: upload failed (#{reason}) — the store simply stays cold")
        Report.count(tally, :push, :skipped)
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
