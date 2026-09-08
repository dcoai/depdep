defmodule Depdep.Config do
  @moduledoc """
  Compile-time configuration, sliced per application.

  Only `config/config.exs` and the env file it imports are compile-time;
  `config/runtime.exs` by definition is not, and is never read here.

  Slicing per app is what keeps objects shareable. A project-wide config digest
  would differ for every consumer, so no two would ever share an object and the
  store would hold one object per consumer per dependency to save nothing.

  One caveat worth checking in your own project: this assumes no value under a
  DEPENDENCY's app is derived from the environment. If `config :some_dep` reads
  `System.get_env/1`, its digest becomes machine-dependent and objects stop
  being portable between a developer's machine and CI. Values under your OWN
  apps may do as they like — they are not part of any dependency's key.

  Config is evaluated with the member's `mix.exs` loaded (`Depdep.Member`), so
  a config that calls into its own project module, or asks `Mix.Project` for the
  build path, sees the member's answers rather than the current directory's.
  """

  @doc """
  Project dir -> `%{app_string => digest}`.

  A project with no `config/` at all yields an empty map, not an error: no
  compile-time config is a perfectly ordinary state, and every app then digests
  as the empty list.
  """
  def read(project_dir, env, root) do
    path = Path.join([project_dir, "config", "config.exs"])

    if File.exists?(path) do
      # `in_project` changes the working directory to the member's, so the path
      # is made absolute before going in.
      config = Path.expand(path)

      project_dir
      |> Depdep.Member.ask(env, fn -> Config.Reader.read!(config, env: env) end)
      |> Map.new(fn {app, values} ->
        {Atom.to_string(app), Depdep.Key.digest([canonical(values, root)])}
      end)
    else
      %{}
    end
  end

  @doc """
  The digest for one app, defaulting to the empty configuration.

  An app nobody configures and an app configured to `[]` are the same input and
  must digest the same, so the default is the real digest of `[]` rather than a
  sentinel.
  """
  def digest_for(config, app), do: Map.get(config, app, Depdep.Key.digest([inspect([])]))

  # `sort_maps` so a map literal in config cannot make the key depend on term
  # ordering, which is not guaranteed stable across releases.
  #
  # The checkout root is replaced with a placeholder. Config legitimately holds
  # absolute paths — esbuild's NODE_PATH again — and without this an object built
  # at /home/you/project could never be reused at /builds/group/project, so
  # nothing a developer compiled would ever serve CI. Where a checkout lives is
  # not an input to a compiler; every other path difference still keys apart.
  defp canonical(term, root) do
    term
    |> inspect(limit: :infinity, printable_limit: :infinity, custom_options: [sort_maps: true])
    |> String.replace(root, "<root>")
  end
end
