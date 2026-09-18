defmodule Mix.Tasks.Depdep.Profile do
  @shortdoc "Checks the depdep profile against what the code emits"

  @moduledoc """
  The depdep profile (`profiles/depdep.exs`) is the vocabulary depdep posts to
  metresis: metric keys, units, polarity, label keys and a dashboard. It is
  owned here rather than in metresis (metresis #206), so it has to be held to
  the code it describes.

      mix depdep.profile check

  Exits non-zero naming every metric or label the code emits that the profile
  does not declare, and every one the profile declares that the code cannot
  emit. Runs in CI.
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
