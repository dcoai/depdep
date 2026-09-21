defmodule Depdep.LockFixture do
  @moduledoc """
  Synthetic lockfile entries, so the key rules can be stated without a network,
  a Hex registry, or a checkout.
  """

  @doc "A hex entry. Children are `name` or `{name, optional?}`."
  def hex(name, version, children, checksum \\ "aaaa") do
    deps =
      Enum.map(children, fn
        {child, optional} ->
          {String.to_atom(child), ">= 0.0.0",
           [hex: String.to_atom(child), repo: "hexpm", optional: optional]}

        child ->
          {String.to_atom(child), ">= 0.0.0",
           [hex: String.to_atom(child), repo: "hexpm", optional: false]}
      end)

    {name, {:hex, String.to_atom(name), version, checksum, [:mix], deps, "hexpm", "bbbb"}}
  end

  @doc "A git entry. The lock records url, ref and opts — and no dependency list."
  def git(name) do
    {name, {:git, "https://example.invalid/#{name}.git", "88ab3a0d", [tag: "v2.1.1"]}}
  end

  @doc "The toolchain is held fixed so a rule cannot pass or fail because of the host."
  def toolchain, do: ["elixir=1.20.4", "otp=29", "env=test"]

  def keys(lock, config \\ %{}) do
    {:ok, keys} = Depdep.Key.compute(Depdep.Deps.from_lock(Map.new(lock)), config, toolchain())
    keys
  end

  @doc """
  Keys with Mix's view supplied: `mix` is `%{name => children}` for the git
  dependencies Mix has fetched (children as `[{name, optional?}]`), or a full
  `%{complete?:, deps:}` view. Every named dependency has the default build
  options unless `opts` says otherwise.
  """
  def keys_with_mix(lock, mix, config \\ %{}) do
    view =
      case mix do
        %{complete?: _, deps: _} -> mix
        children -> %{complete?: true, deps: Map.new(children, fn {n, c} -> {n, dep_info(c)} end)}
      end

    {:ok, keys} =
      Depdep.Key.compute(Depdep.Deps.from_lock(Map.new(lock), view), config, toolchain())

    keys
  end

  @doc "Mix's view of one dependency, as `Depdep.Deps.mix_view/2` would give it."
  def dep_info(children, opts \\ []) do
    %{
      children: children,
      env: Keyword.get(opts, :env, :prod),
      compile: Keyword.get(opts, :compile),
      system_env: Keyword.get(opts, :system_env, [])
    }
  end

  @doc "The hash for one name, or `{:skip, reason}`."
  def key(lock, name, config \\ %{}) do
    case Map.fetch!(keys(lock, config), name) do
      {:key, hash} -> hash
      {:skip, reason} -> {:skip, reason}
    end
  end

  @doc "Write a lockfile, read it back through the real adapter, remove it."
  def write_and_read(contents) do
    path =
      Path.join(System.tmp_dir!(), "depdep-fixture-#{:erlang.unique_integer([:positive])}.lock")

    File.write!(path, contents)
    result = Depdep.Lock.read(path)
    File.rm(path)
    result
  end
end
