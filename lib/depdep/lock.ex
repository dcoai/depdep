defmodule Depdep.Lock do
  @moduledoc """
  Reads `mix.lock` and answers what each dependency declares.

  `mix.lock` is an Elixir map literal, so it is evaluated rather than parsed. Hex
  entries carry the full dependency spec INCLUDING optionality, which is what
  makes the whole closure computable without fetching anything:

      "ash": {:hex, :ash, "3.32.3", "<inner>", [:mix],
        [{:plug, ">= 0.0.0", [hex: :plug, repo: "hexpm", optional: true]}, ...],
        "hexpm", "<outer>"}
  """

  @doc """
  Path -> `%{name => entry}` or `{:error, reason}`.

  **Keys are normalised to strings, and that is not cosmetic.** A generated
  `mix.lock` writes `"ash": {...}`, and in Elixir a quoted keyword inside a map
  literal is an ATOM key — `%{"ash": v}` is `%{ash: v}`, not `%{"ash" => v}`.
  Left alone, every `Map.has_key?(lock, "plug")` answers false, every optional
  dependency looks unresolved, and every build of a package with optional
  dependencies collapses to one key. That is a wrong-restore, and a wrong restore
  is invisible: measured in `dco-tek/bizex`, one compiled in 2.3 s and passed
  106/106 tests while `Ash.Type.File.Source` silently resolved to `Any`.
  `children/1` already returns strings, so normalising here makes both sides of
  every lookup agree.

  Evaluated inside `Code.with_diagnostics/1` because the parser emits one
  unnecessary-quotes warning per package — over a hundred lines per project,
  which would bury the hit/miss reporting this exists to produce. Captured and
  dropped rather than silenced globally.
  """
  def read(path) do
    if File.exists?(path) do
      {{lock, _bindings}, _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.eval_string(File.read!(path), [], file: path)
        end)

      if is_map(lock) do
        {:ok, Map.new(lock, fn {name, entry} -> {to_string(name), entry} end)}
      else
        {:error, "#{path} did not evaluate to a map"}
      end
    else
      {:error, "no lockfile at #{path}"}
    end
  end

  @doc """
  The children a dependency declares, as `{name, optional?}`.

  Git entries carry NO dependency list — the lock records only url, ref and
  opts — so their closure is unknowable from here and they are reported as such
  rather than guessed at.
  """
  def children(entry, graph \\ %{}, name \\ nil)

  def children(entry, _graph, _name) when elem(entry, 0) == :hex do
    entry
    |> elem(5)
    |> Enum.map(fn {app, _requirement, opts} ->
      {Atom.to_string(app), Keyword.get(opts, :optional, false)}
    end)
    |> Enum.sort()
  end

  # A git entry records url, ref and opts and no dependency list, so its closure
  # is unknowable from here alone. `Depdep.Graph` supplies the edges Mix already
  # resolved; without them this stays `:unknown` and the dependency is skipped,
  # which is the fail-safe direction it has always been.
  #
  # Optionality is not carried, and does not need to be: an unresolved optional
  # child has no edge, so it is absent from this list exactly as it would be
  # absent from a hex entry's resolved set, and the key differs accordingly.
  def children(entry, graph, name) when elem(entry, 0) == :git do
    case Map.fetch(graph, name) do
      {:ok, children} -> children |> Enum.map(&{&1, false}) |> Enum.sort()
      :error -> :unknown
    end
  end

  def children(_entry, _graph, _name), do: :unknown

  def hex?(entry), do: elem(entry, 0) == :hex

  def version(entry) when elem(entry, 0) == :hex, do: elem(entry, 2)

  # The tag names the version a human pinned; the sha is the fallback when a ref
  # was pinned directly.
  def version(entry) when elem(entry, 0) == :git do
    case Keyword.get(elem(entry, 3), :tag) do
      nil -> elem(entry, 2)
      tag -> tag
    end
  end

  def inner_checksum(entry) when elem(entry, 0) == :hex, do: elem(entry, 3)

  # The ref sha IS the content identity, and a stronger one than hex's checksum:
  # it names the exact tree, not a package tarball someone assembled from it.
  def inner_checksum(entry) when elem(entry, 0) == :git, do: elem(entry, 2)

  def build_tools(entry) when elem(entry, 0) == :hex, do: entry |> elem(4) |> inspect()

  # A git entry does not record its build tools. Constant rather than absent, so
  # the key composition is the same shape for both kinds.
  def build_tools(entry) when elem(entry, 0) == :git, do: "git"
end
