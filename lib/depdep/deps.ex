defmodule Depdep.Deps do
  @moduledoc """
  A member's dependencies as Mix sees them — the one place depdep asks.

  Everything the key needs about a dependency, Mix already holds: its lock
  entry, its children, whether this `MIX_ENV` builds it at all, and the build
  options its declaration carries. Depdep used to re-derive three of those —
  parse the lock, shell out to `mix deps.tree` and parse the dot, and walk the
  `only:` rule by hand — and every recent defect (#62, #70, #79, #80, #81) was
  an edge of a rule Mix owns, got slightly wrong. This module asks instead,
  with the converge `mix deps` runs, inside the member's project, and turns each
  `%Mix.Dep{}` into a plain map so nothing else in depdep touches Mix's
  internal struct (#89).

  ## What a pass can know

  Mix's converger lists the dependencies **active for the env**: `only:` is applied, a path dependency's closure is in the list like
  anything else, and a fetched dependency's children are its own `mix.exs`'s
  prod deps. A dependency not yet fetched has no children Mix can read, so:

    * **After `mix deps.get`** the list is complete. A lock entry not in it is
      *not for this env*, exactly.
    * **Before `mix deps.get`** the list is incomplete, and a lock entry not
      in it may be a child of something unfetched. Nothing is called inactive:
      every lock entry is requested, and `--mix-get`'s second pass — with the
      list complete — settles the question and re-buckets the misses that
      were never buildable. The cost is a few extra store requests in the
      first pass; the alternative was a walk of the lock that this module
      exists to delete.

  Children for the key come from the lock entry for a hex dependency (it
  carries them, with optionality, fetched or not — so a hex key is the same
  in both passes) and from Mix for a git dependency once it is fetched; before
  that a git dependency's closure is unknown and it is skipped, as it always
  was. Build options (`env:`, `compile:`, `system_env:`) come from the
  declaration Mix loaded; a transitive dependency not yet in Mix's list has
  the defaults, which is what its declaration in its parent's `mix.exs` will
  say — only a top-level declaration can set them, and top-level dependencies
  are in the list fetched or not.
  """

  alias Depdep.{Lock, Member}

  @typedoc """
  One lock entry, with what Mix adds:

    * `entry` — the lock tuple.
    * `children` — `[{name, optional?}]`, or `:unknown` for a git dependency
      not yet fetched.
    * `active?` — `true`/`false` once Mix's list is complete, `nil` before
      `mix deps.get` when it cannot be known.
    * `env`, `compile`, `system_env` — the declaration's build options.
  """
  @type t :: %{
          entry: tuple(),
          children: [{String.t(), boolean()}] | :unknown,
          active?: boolean() | nil,
          env: atom(),
          compile: String.t() | nil,
          system_env: [{String.t(), String.t()}]
        }

  @doc """
  Project directory -> `{:ok, %{name => t}}` or `{:error, reason}`.

  The lock is read by `Depdep.Lock.read/1` (a lock that does not parse raises,
  and a missing one is the error the provider reports). Mix is asked inside
  the member's project; a member with no `mix.exs` has no env rule to apply,
  so everything is active and nothing is said.
  """
  def read(project_dir, env) do
    with {:ok, lock} <- Lock.read(Path.join(project_dir, "mix.lock")) do
      {:ok, from_lock(lock, mix_view(project_dir, env))}
    end
  end

  @doc """
  The pure half of `read/2`: a lock plus Mix's view, as `%{name => t}`.

  `mix` is `%{complete?: boolean, deps: %{name => %{children, env, compile,
  system_env}}}` — what `mix_view/2` returns — or `:unknown` for a member
  with no `mix.exs` (everything active), or `nil` when Mix was not asked,
  which reads as an incomplete view. Public so the key rules can be stated
  over a lock without a project on disk.
  """
  def from_lock(lock, mix \\ nil) do
    %{complete?: complete?, deps: seen} =
      case mix do
        nil -> %{complete?: false, deps: %{}}
        :unknown -> %{complete?: :unknown, deps: %{}}
        view -> view
      end

    Map.new(lock, fn {name, entry} ->
      known = Map.get(seen, name)

      {name,
       %{
         entry: entry,
         children: children(entry, known),
         active?: active?(complete?, known),
         env: (known && known.env) || :prod,
         compile: known && known.compile,
         system_env: (known && known.system_env) || []
       }}
    end)
  end

  # No `mix.exs` means no `only:` rule to apply: nothing can be excluded and
  # nothing needs settling, so everything is active — the behaviour before
  # the env question existed.
  defp active?(:unknown, _known), do: true
  defp active?(true, known), do: known != nil
  defp active?(false, _known), do: nil

  # A hex entry carries its children in the lock, fetched or not; that is
  # what makes a hex key the same in both passes. A git entry carries none,
  # so its children are Mix's once it is fetched and unknown until then.
  defp children(entry, _known) when elem(entry, 0) == :hex do
    entry
    |> elem(5)
    |> Enum.map(fn {app, _requirement, opts} ->
      {Atom.to_string(app), Keyword.get(opts, :optional, false)}
    end)
    |> Enum.sort()
  end

  defp children(entry, %{children: children}) when elem(entry, 0) == :git and children != nil,
    do: children

  defp children(_entry, _known), do: :unknown

  @doc """
  Mix's view of the member: `%{complete?: boolean, deps: %{name => info}}`.

  One converge inside the member's project (`converged/2`), or `:unknown`
  when there is no `mix.exs` to ask. `complete?` is whether every dependency
  Mix lists is fetched — the condition under which "not in the list" means
  "not for this env". A git dependency's `children` are read only when it is
  fetched; `nil` otherwise.
  """
  def mix_view(project_dir, env) do
    if File.exists?(Path.join(project_dir, "mix.exs")) do
      deps = converged(project_dir, env)

      %{
        complete?: Enum.all?(deps, &Mix.Dep.available?/1),
        deps: Map.new(deps, &{Atom.to_string(&1.app), info(&1)})
      }
    else
      :unknown
    end
  end

  @doc """
  The member's converged `%Mix.Dep{}` list for `env`, asked inside its project.

  `Mix.Dep.Converger.converge/1` rather than `Mix.Dep.load_and_cache/0`: the
  latter treats a project pushed on top of another as a *dependency* of the
  one beneath and takes its deps from that one's cache — inside `mix test`
  that is depdep's own project, and the answer is `[]`. The converger reads
  the project on top of the stack. The Hex archive is re-appended first
  because Mix prunes archive paths before compiling, and a hex dependency's
  SCM lives there.
  """
  def converged(project_dir, env, opts \\ []) do
    deps =
      Member.ask(project_dir, env, fn ->
        Mix.Local.append_archives()
        Mix.Dep.clear_cached()

        if Keyword.get(opts, :compile_env, false) do
          with_application_env(project_dir, env, fn -> Mix.Dep.Converger.converge(env: env) end)
        else
          Mix.Dep.Converger.converge(env: env)
        end
      end)

    # Mix loaded every path dependency's project under its own app name. Recording
    # that means a later question about the same directory — as a MEMBER, in a
    # poncho where members are each other's path dependencies — reuses Mix's cache
    # instead of recompiling the `mix.exs` and printing `redefining module` (#132).
    for %Mix.Dep{scm: Mix.SCM.Path, app: app, opts: opts} <- deps, dest = opts[:dest] do
      Member.remember(dest, app)
    end

    deps
  end

  # **A dependency's status depends on the application env, and nothing put the member's
  # config there** (#161, for #141). `Mix.Dep.Loader`'s `compile_env_status/2` calls
  # `Config.Provider.valid_compile_env?/1`, which compares the value a dependency
  # recorded at build time against `Application.fetch_env` IN THIS VM. With the member's
  # config absent, a dependency recording any value the consumer sets to a non-default is
  # `:envoutdated` — so a correct restore was refused, and refused again every run,
  # because the object in the store was never wrong.
  #
  # Read with `Config.Reader.read!/2` exactly as `Depdep.Config.read/3` does, and for the
  # same reason: a `config/config.exs` is ordinary Elixir that may call its own `mix.exs`,
  # so it is evaluable only with the project loaded — which it is, since this runs inside
  # `Member.ask`.
  #
  # Only the restore check asks for it. The key path does not need it, and
  # `Depdep.Config.digest_for/2` reads the config it is HANDED rather than the application
  # env, so the key is unaffected either way.
  defp with_application_env(project_dir, env, fun) do
    path = Path.expand(Path.join([project_dir, "config", "config.exs"]))

    if File.exists?(path) do
      config = Config.Reader.read!(path, env: env)
      previous = for {app, _} <- config, do: {app, Application.get_all_env(app)}

      Application.put_all_env(config, persistent: true)
      result = fun.()

      # Put back what was there, so depdep's own VM does not keep a consumer's config.
      # On the normal path only: a raise ends the run, and `Member.ask` documents that
      # nothing here is rescued.
      restore_application_env(previous)
      result
    else
      fun.()
    end
  end

  # Delete what the member's config added, then put back what was there. Deleting first
  # matters: a key the member set and the previous env did not have would otherwise
  # survive.
  defp restore_application_env(previous) do
    for {app, values} <- previous do
      for {key, _} <- Application.get_all_env(app), not List.keymember?(values, key, 0) do
        Application.delete_env(app, key, persistent: true)
      end

      Application.put_all_env([{app, values}], persistent: true)
    end
  end

  # The fields used, and nothing else, so a change in `%Mix.Dep{}` is one
  # function's problem — pinned by a test.
  defp info(%Mix.Dep{} = dep) do
    %{
      children:
        if Mix.Dep.available?(dep) do
          dep.deps
          |> Enum.map(&{Atom.to_string(&1.app), Keyword.get(&1.opts, :optional, false)})
          |> Enum.sort()
        end,
      env: Keyword.get(dep.opts, :env, :prod),
      compile: Keyword.get(dep.opts, :compile),
      system_env:
        dep.system_env |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Enum.sort()
    }
  end

  @doc "The `%Mix.Dep{}` fields this module reads — what the pin test checks."
  def mix_dep_fields, do: ~w(app status deps opts system_env)a
end
