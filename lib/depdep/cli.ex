defmodule Depdep.CLI do
  @moduledoc """
  The command line: `--plan`, `--pull`, `--push`.

  Invoked from a consumer's bootstrap script, which is how depdep runs before
  `mix deps.get` without being a dependency of the project it is serving:

      Mix.install([{:depdep, git: "...", tag: "v0.1.0"}])
      Depdep.CLI.main(System.argv())
  """

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
        totals = Enum.map(projects, &transfer_project(root, &1, env, direction, cfg))
        report(direction, totals)
    end
  end

  defp transfer_project(root, project, env, direction, cfg) do
    case Depdep.keys_for(root, project, env) do
      {:error, reason} ->
        warn("#{project}: #{reason} — every dependency will be compiled")
        {0, 0, 0}

      {:ok, keys, lock} ->
        project_dir = Path.join(root, project)

        keys
        |> Enum.sort()
        |> Enum.reduce({0, 0, 0}, fn entry, acc ->
          step(entry, project, lock, project_dir, env, direction, cfg, acc)
        end)
    end
  end

  defp step({name, {:skip, reason}}, project, _lock, _dir, _env, _direction, _cfg, {h, m, s}) do
    warn("#{project}/#{name}: skipped — #{reason}")
    {h, m, s + 1}
  end

  defp step({name, {:key, hash}}, project, lock, project_dir, env, direction, cfg, {h, m, s}) do
    object = Depdep.Key.object(name, Map.fetch!(lock, name), hash)

    # Both trees, not just the build: a dependency with `_build` but no `deps`
    # would be treated as present, and Mix would then recompile it the moment
    # `mix deps.get` fetched the source. See `Depdep.Archive`.
    case {direction, Depdep.Archive.complete?(project_dir, name, env)} do
      # Already present locally. Pull has nothing to do; push offers it to the store.
      {:pull, true} -> {h, m, s + 1}
      {:pull, false} -> pull_one(cfg, object, project_dir, project, name, {h, m, s})
      {:push, false} -> {h, m, s + 1}
      {:push, true} -> push_one(cfg, object, project_dir, env, project, name, {h, m, s})
    end
  end

  defp pull_one(cfg, object, project_dir, project, name, {h, m, s}) do
    tmp = tmp_path()

    result =
      case Depdep.S3.get(cfg, object, tmp) do
        :ok -> Depdep.Archive.extract(tmp, project_dir)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        {h + 1, m, s}

      {:error, "not found"} ->
        {h, m + 1, s}

      {:error, reason} ->
        warn("#{project}/#{name}: pull failed (#{reason}) — Mix will compile it")
        {h, m + 1, s}
    end
  end

  defp push_one(cfg, object, project_dir, env, project, name, {h, m, s}) do
    case Depdep.S3.head(cfg, object) do
      :hit ->
        {h + 1, m, s}

      :miss ->
        upload(cfg, object, project_dir, env, project, name, {h, m, s})

      {:error, reason} ->
        warn("#{project}/#{name}: HEAD failed (#{reason}) — not uploading")
        {h, m, s + 1}
    end
  end

  defp upload(cfg, object, project_dir, env, project, name, {h, m, s}) do
    tmp = tmp_path()

    result =
      case Depdep.Archive.create(project_dir, name, env, tmp) do
        :ok -> Depdep.S3.put(cfg, object, tmp)
        other -> other
      end

    File.rm(tmp)

    case result do
      :ok ->
        {h, m + 1, s}

      {:error, reason} ->
        warn("#{project}/#{name}: upload failed (#{reason}) — the store simply stays cold")
        {h, m, s + 1}
    end
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "depdep-#{:erlang.unique_integer([:positive])}.tar.gz")

  defp report(direction, totals) do
    {h, m, s} =
      Enum.reduce(totals, {0, 0, 0}, fn {a, b, c}, {x, y, z} -> {a + x, b + y, c + z} end)

    case direction do
      :pull -> IO.puts("depdep: pulled #{h}, missing #{m}, skipped #{s}")
      :push -> IO.puts("depdep: already stored #{h}, uploaded #{m}, skipped #{s}")
    end
  end

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
