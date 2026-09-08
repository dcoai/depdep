defmodule Depdep.Member do
  @moduledoc """
  Ask Mix about a member, with the member's own `mix.exs` loaded.

  Two things depdep reads are only fully defined once Mix has loaded the
  project: where it builds (`Mix.Project.build_path/0` — #25) and what its
  compile-time configuration says. A `config/config.exs` is ordinary Elixir and
  can call anything: `dco-tek/metresis` picks its Ecto adapter with
  `Metresis.MixProject.repo_adapter()`, and both it and `dco-tek/bizex` build
  esbuild's `NODE_PATH` from `Mix.Project.build_path()`. Evaluated under plain
  `elixir` with no project on Mix's stack, the first raises `UndefinedFunctionError`
  and the second answers from the current directory — a digest that depends on
  where depdep was launched from, which is exactly the machine-dependence
  `Depdep.Config` warns consumers against in their own config.

  So every question about a member is asked the same way: inside
  `Mix.Project.in_project/4`, which compiles the member's `mix.exs` and pushes it
  as the current project for the duration of the function. Mix is the authority
  on what a project says; this module is the one place depdep asks.

  ## Once per member

  `in_project/4` keys its cache of loaded projects by the app name it is given.
  A fresh name per call would recompile `mix.exs` each time and, since the
  module from the first compile is still loaded, print
  `warning: redefining module` into every consumer's log — once per member per
  question asked. The app name here is derived from the member's expanded
  directory, so the second question about a member is a cache hit: no compile,
  no warning, and two members with the same app name in different directories
  never collide.
  """

  @doc """
  Runs `fun` with `project_dir`'s `mix.exs` loaded as the current Mix project.

  Starts the Mix application and sets `Mix.env/1` first; both are idempotent.
  A directory without a `mix.exs` is still entered — Mix pushes an empty project
  and answers its defaults relative to that directory — so callers need no
  special case for it.

  Whatever `fun` raises propagates. Nothing here is rescued: a member whose
  `mix.exs` or config cannot be evaluated is one `mix` cannot evaluate either,
  and the `Depdep` moduledoc says why that must stop the run rather than
  become a skip.
  """
  def ask(project_dir, env, fun) when is_function(fun, 0) do
    {:ok, _} = Application.ensure_all_started(:mix)
    Mix.env(env)

    dir = Path.expand(project_dir)
    Mix.Project.in_project(app_for(dir), dir, fn _module -> fun.() end)
  end

  # Unique by construction, not by hashing: the atom IS the path. Members are
  # few, so the atom table cost is bounded by the poncho's size.
  defp app_for(dir), do: String.to_atom("depdep_member " <> dir)
end
