defmodule Mix.Tasks.Depdep.Profile do
  @shortdoc "Checks the depdep profile against the code"

  @moduledoc """
  The depdep profile (`priv/profiles/depdep.exs`) is the vocabulary depdep posts to
  metresis: metric keys, units, polarity, label keys and a dashboard. It is
  owned here rather than in metresis (metresis #206), so it has to be held to
  the code it describes.

      mix depdep.profile check

  `check` exits non-zero naming every metric or label the code emits that the
  profile does not declare, and every one the profile declares that the code
  cannot emit. Runs in CI on every pipeline.

  Reaching metresis is not this task's job any more: every ingest post carries
  the profile's hash, and an instance that lacks it is sent the document by
  the same run, with the same token (`Depdep.Metresis`, #86). The `publish`
  subcommand and the admin token it needed are gone with that.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["check"]) do
    case Depdep.Profile.check() do
      :ok ->
        Mix.shell().info("depdep profile: #{Depdep.Profile.path()} agrees with the code")

      {:error, problems} ->
        Enum.each(problems, &Mix.shell().error("depdep profile: #{&1}"))
        Mix.raise("#{length(problems)} disagreement(s) between the profile and the code")
    end
  end

  def run(_argv), do: Mix.raise("usage: mix depdep.profile check")
end
