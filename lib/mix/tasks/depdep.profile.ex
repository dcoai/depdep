defmodule Mix.Tasks.Depdep.Profile do
  @shortdoc "Checks the depdep profile against the code"

  @moduledoc """
  The depdep profile (`priv/profiles/depdep.exs`) is the vocabulary depdep posts to
  metresis: metric keys, units, polarity, label keys and a dashboard. It is
  owned here rather than in metresis (metresis #206), so it has to be held to
  the code it describes.

      mix depdep.profile check
      mix depdep.profile check --instance

  `check` exits non-zero naming every metric or label the code emits that the
  profile does not declare, and every one the profile declares that the code
  cannot emit. Runs in CI on every pipeline.

  Reaching metresis is not this task's job any more: every ingest post carries
  the profile's hash, and an instance that lacks it is sent the document by
  the same run, with the same token (`Depdep.Metresis`, #86). The `publish`
  subcommand and the admin token it needed are gone with that.

  `check --instance` asks an instance what it holds — `GET /api/v1/profiles/
  depdep` with `DEPDEP_METRESIS_TOKEN`, whose `ingest` capability implies the
  `catalog_read` this needs — and names every difference. **Drift detection,
  not authority**: it publishes nothing, and the emitter still publishes
  through the data path. It exists because a check that only reads the local
  tree cannot see this class of drift, which is how four metrics sat
  catalogued as bare numbers for two releases (#100).

  An instance that is not configured, or cannot be reached, is a warning and
  exit 0 — every other `DEPDEP_METRESIS_*` path in depdep is optional, and a
  check that failed a pipeline because one host is down would be the single
  failure mode this project does not have. A *reachable* instance that
  disagrees exits non-zero.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["check", "--instance"]) do
    case instance_document() do
      {:skip, why} ->
        Mix.shell().info("depdep profile: #{why} — nothing compared")

      {:ok, url, theirs} ->
        case Depdep.Profile.compare(Depdep.Profile.read(), theirs, url) do
          [] ->
            Mix.shell().info("depdep profile: #{url} holds what this depdep ships")

          problems ->
            Enum.each(problems, &Mix.shell().error("depdep profile: #{&1}"))

            Mix.raise(
              "#{length(problems)} difference(s) between the profile and #{url} — " <>
                "the instance is sent this document on the next post that meets a 428"
            )
        end
    end
  end

  def run(["check"]) do
    case Depdep.Profile.check() do
      :ok ->
        Mix.shell().info("depdep profile: #{Depdep.Profile.path()} agrees with the code")

      {:error, problems} ->
        Enum.each(problems, &Mix.shell().error("depdep profile: #{&1}"))
        Mix.raise("#{length(problems)} disagreement(s) between the profile and the code")
    end
  end

  def run(_argv), do: Mix.raise("usage: mix depdep.profile check [--instance]")

  # `{:ok, url, document | :absent}`, or `{:skip, why}` for anything that
  # means "there is nothing to compare against", which is never a failure.
  defp instance_document do
    case Depdep.Metresis.config() do
      :disabled ->
        {:skip, "no metresis configured (DEPDEP_METRESIS and DEPDEP_METRESIS_TOKEN)"}

      {:error, reason} ->
        {:skip, reason}

      {:ok, cfg} ->
        fetch(cfg)
    end
  end

  defp fetch(cfg) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    url = cfg.profiles_url <> "/depdep"
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(cfg.token)}]
    request = {String.to_charlist(url), headers}
    options = [connect_timeout: 5_000, timeout: 15_000]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        {:ok, instance_of(cfg), decode(body, url)}

      {:ok, {{_, 404, _}, _, _}} ->
        {:ok, instance_of(cfg), :absent}

      {:ok, {{_, status, _}, _, body}} ->
        {:skip, "#{url} answered #{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:skip, "#{url} is not reachable (#{inspect(reason)})"}
    end
  end

  # `Depdep.Json` writes and does not read, deliberately — depdep consumes no
  # JSON at runtime. This is a Mix task, not the path a consumer runs before
  # `mix deps.get`, so it may use the standard library's reader; Elixir gained
  # one in 1.18 and `mix.exs` supports 1.15, hence the guard.
  defp decode(body, url) do
    if Code.ensure_loaded?(JSON) do
      JSON.decode!(body)
    else
      Mix.raise(
        "mix depdep.profile check --instance needs Elixir 1.18 or later to read #{url}'s answer"
      )
    end
  end

  defp instance_of(cfg), do: String.replace_suffix(cfg.profiles_url, "/api/v1/profiles", "")
end
