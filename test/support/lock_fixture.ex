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
    {:ok, keys} = Depdep.Key.compute(Map.new(lock), config, toolchain())
    keys
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
