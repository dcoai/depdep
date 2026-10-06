defmodule Depdep.Lock do
  @moduledoc """
  Reads `mix.lock` and answers what each dependency declares.

  `mix.lock` is an Elixir map literal, so it is evaluated rather than parsed. Hex
  entries carry the full dependency spec INCLUDING optionality, which is what
  lets `Depdep.Deps` know a hex dependency's children before anything is
  fetched:

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
  `Depdep.Deps` keys its map by these strings, so normalising here makes both
  sides of every lookup agree.

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

  @doc """
  The repository URL a git entry names, and `nil` for a hex entry.

  **Deliberately not a key input.** The sha already identifies the content, so one
  object serves every way of spelling its address — otherwise the same commit
  would be stored once per spelling. The URL matters only on restore, because
  `Mix.SCM.Git.lock_status/1` compares the lock's URL against the checkout's
  `remote.origin.url` as strings, and a restored checkout keeps the pusher's
  (#123).
  """
  def repo(entry) when elem(entry, 0) == :git, do: elem(entry, 1)
  def repo(entry) when elem(entry, 0) == :hex, do: nil

  def build_tools(entry) when elem(entry, 0) == :hex, do: entry |> elem(4) |> inspect()

  # A git entry does not record its build tools. Constant rather than absent, so
  # the key composition is the same shape for both kinds.
  def build_tools(entry) when elem(entry, 0) == :git, do: "git"
end
