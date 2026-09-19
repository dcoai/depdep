defmodule Mix.Tasks.Depdep.Profile do
  @shortdoc "Checks the depdep profile against the code, or publishes it to metresis"

  @moduledoc """
  The depdep profile (`priv/profiles/depdep.exs`) is the vocabulary depdep posts to
  metresis: metric keys, units, polarity, label keys and a dashboard. It is
  owned here rather than in metresis (metresis #206), so it has to be held to
  the code it describes, and it has to reach metresis from here.

      mix depdep.profile check
      mix depdep.profile publish [--no-adopt]

  `check` exits non-zero naming every metric or label the code emits that the
  profile does not declare, and every one the profile declares that the code
  cannot emit. Runs in CI on every pipeline.

  `publish` POSTs the document to `DEPDEP_METRESIS_URL` with
  `DEPDEP_METRESIS_ADMIN_TOKEN` and adopts it on that token's domain in the
  same request. Runs in CI on tag pipelines only, where the admin token exists.
  A missing variable is a usage error rather than a silent skip: this task is
  only ever run where publishing is intended, and doing nothing quietly is how
  a domain stays on provisional definitions for a year.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["publish" | flags]) do
    {opts, [], []} = OptionParser.parse(flags, strict: [adopt: :boolean])
    url = required("DEPDEP_METRESIS_URL")
    token = required("DEPDEP_METRESIS_ADMIN_TOKEN")

    case Depdep.Profile.publish(Depdep.Profile.read(), url, token, adopt: opts[:adopt] != false) do
      {:ok, answer} ->
        Mix.shell().info("depdep profile: published to #{url}")
        Mix.shell().info(answer)

      {:error, message} ->
        Mix.raise("depdep profile: metresis refused the profile — #{message}")
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

  def run(_argv), do: Mix.raise("usage: mix depdep.profile check | publish [--no-adopt]")

  defp required(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> Mix.raise("depdep profile: #{name} is not set")
      value -> String.trim(value)
    end
  end
end
