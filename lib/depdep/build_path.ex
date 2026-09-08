defmodule Depdep.BuildPath do
  @moduledoc """
  Where a member actually compiles to.

  Almost every project builds into `_build/<env>`, and depdep assumed that
  literally. A project that sets `build_path` in its `mix.exs` compiles
  somewhere else — `dco-tek/metresis` does, because its storage adapter is
  compiled into the repo module and its two backends cannot share one build:

      build_path: "_build/\#{db_backend()}"    # -> _build/sqlite/test

  Against such a project depdep restored into `_build/test/lib/*`, which Mix
  never reads, so everything compiled anyway; and `--push` reported `not built
  here` for all 49 dependencies because the place it looked was empty. **A
  restore and a full compile — the slow case — arrived at in silence.**

  So ask Mix rather than assuming. `Depdep.Member.ask/3` runs the member's own
  `mix.exs` in Mix's own context, which is the same answer #35 reached for git
  dependencies: Mix is the authority on what a project says.

  ## This is a path, not a key

  The answer never enters `Depdep.Key`, and that is deliberate: identical beams
  do not depend on the directory they were written to, and metresis's two
  backends should share objects. So a wrong answer here costs a miss, never a
  wrong restore — categorically unlike the dependency lists in #8, which feed
  the key.
  """

  @doc """
  The build directory for a member, relative to it.

  `{:ok, relative}`, or `{:error, reason}` when the project builds somewhere an
  object cannot represent.

  Falls back to `_build/<env>` whenever the project cannot be loaded. That is
  the right answer for every project that does not set `build_path`, so it is
  the default rather than a recovery.
  """
  def for_project(project_dir, env) do
    absolute = resolve(project_dir, env)
    relative = Path.relative_to(absolute, Path.expand(project_dir))

    cond do
      relative == absolute ->
        # `relative_to/2` hands back the input unchanged when it is not beneath
        # the base. An object is rooted at the member, so a build outside it
        # cannot be represented — and writing one anyway would restore into a
        # place nobody asked for.
        {:error, "builds outside the project, at #{absolute} — cannot be stored"}

      true ->
        {:ok, relative}
    end
  end

  # `Mix.Project.build_path/0` already includes the environment — it answers
  # `<dir>/_build/sqlite/test`, not `<dir>/_build/sqlite` — so the env is never
  # appended here. A member without a `mix.exs` is entered all the same and
  # answers Mix's default, which is the `_build/<env>` every other project uses.
  defp resolve(project_dir, env) do
    default = Path.expand(Path.join([project_dir, "_build", to_string(env)]))

    case Depdep.Member.ask(project_dir, env, fn -> Mix.Project.build_path() end) do
      path when is_binary(path) -> path
      _ -> default
    end
  end
end
