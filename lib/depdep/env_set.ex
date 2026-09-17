defmodule Depdep.EnvSet do
  @moduledoc """
  Which lock entries the current `MIX_ENV` will ever build.

  A `mix.lock` lists every dependency the project has resolved under *any*
  environment, and depdep used to key and request all of them. Under
  `MIX_ENV=test` that asked the store for `ex_doc` and its five-package chain on
  every job of every pipeline — objects no `--push` will ever produce, because
  nothing compiles a `only: :dev` dependency in a test job. Measured on
  `dco-tek/visualize`: 648 misses over 72 pulls, every one structural, against
  2,736 hits (#58). A miss that cannot become a hit makes `missing N` unreadable
  as the number it exists to be.

  Mix's own rule is reproduced here rather than asked for: `Mix.Dep.Loader`
  needs every dependency's source on disk to answer, and the first pull runs
  before `mix deps.get`. The rule is small. A direct dependency is active when
  its `only:` admits the env; a transitive one is active when a non-optional
  edge reaches it from an active parent. A dependency's own dev and test deps
  are never transitive, and the lock's hex entries carry exactly the non-dev
  edges, so walking them is walking Mix's graph.

  ## Three answers, not two

  A git entry carries no child list until `Depdep.Graph` has read Mix's
  resolution after `deps.get`. Before that, a lock entry the walk did not reach
  is either outside the env or a child of that git dependency, and there is no
  telling which. Calling it inactive would be a silent wrong answer in the
  worst direction: never pulled, never pushed, compiled from source on every
  run, and reported as *not for this env*. So such an entry is `:ambiguous` —
  keyed and requested exactly as it always was, with one warning naming the
  cause — until a pass with the graph can decide. Only an entry provably outside
  the closure is `:inactive`.

  `:unknown` declared dependencies (no `mix.exs` to read) make everything
  `:active`, which is the behaviour before this module existed.
  """

  @type verdict :: :active | :inactive | :ambiguous

  @doc """
  The project's direct dependencies that are active under `env`, as names, or
  `:unknown` when there is no `mix.exs` to declare them.

  Asked of Mix with the member's `mix.exs` loaded (`Depdep.Member.ask/3`), so a
  `deps/0` that computes its list — `visualize` builds one from whether a
  sibling checkout exists — answers as Mix would see it. `targets:` is not
  consulted: depdep has no `MIX_TARGET`, and a dependency excluded by target is
  still resolved and fetched by Mix for the default target.
  """
  def declared(project_dir, env) do
    if File.exists?(Path.join(project_dir, "mix.exs")) do
      deps = Depdep.Member.ask(project_dir, env, fn -> Mix.Project.config()[:deps] || [] end)

      deps
      |> Enum.filter(&admits?(&1, env))
      |> Enum.map(&Atom.to_string(elem(&1, 0)))
      |> Enum.sort()
    else
      :unknown
    end
  end

  # The three spellings Mix accepts: `{app, req}`, `{app, opts}`, `{app, req, opts}`.
  defp admits?({_app, req}, _env) when is_binary(req), do: true
  defp admits?({_app, opts}, env) when is_list(opts), do: only_admits?(opts[:only], env)
  defp admits?({_app, _req, opts}, env), do: only_admits?(opts[:only], env)

  defp only_admits?(nil, _env), do: true
  defp only_admits?(only, env) when is_atom(only), do: only == env
  defp only_admits?(only, env) when is_list(only), do: env in only

  @doc """
  A verdict for every entry in `lock`: `%{name => :active | :inactive | :ambiguous}`.

  `direct` is `declared/2`'s answer. `graph` is `Depdep.Graph`'s, and may be
  empty — that is what makes `:ambiguous` possible.
  """
  def classify(:unknown, lock, _graph), do: Map.new(lock, fn {name, _} -> {name, :active} end)

  def classify(direct, lock, graph) do
    roots = Enum.filter(direct, &Map.has_key?(lock, &1))
    {reached, complete?} = walk(roots, lock, graph, MapSet.new(), true)

    Map.new(lock, fn {name, _entry} ->
      cond do
        MapSet.member?(reached, name) -> {name, :active}
        complete? -> {name, :inactive}
        true -> {name, :ambiguous}
      end
    end)
  end

  # Non-optional edges only. An optional child is Mix's to include only when
  # something reaches it non-optionally — and then that edge reaches it here.
  # A top-level `optional: true` is a promise to the project's OWN consumers
  # and does not exclude the dependency from this project, so roots are taken
  # as declared.
  defp walk([], _lock, _graph, reached, complete?), do: {reached, complete?}

  defp walk([name | rest], lock, graph, reached, complete?) do
    if MapSet.member?(reached, name) do
      walk(rest, lock, graph, reached, complete?)
    else
      reached = MapSet.put(reached, name)

      case Depdep.Lock.children(Map.fetch!(lock, name), graph, name) do
        :unknown ->
          walk(rest, lock, graph, reached, false)

        children ->
          next =
            for {child, optional?} <- children,
                not optional?,
                Map.has_key?(lock, child),
                do: child

          walk(next ++ rest, lock, graph, reached, complete?)
      end
    end
  end
end
