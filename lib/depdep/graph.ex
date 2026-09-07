defmodule Depdep.Graph do
  @moduledoc """
  The dependency edges Mix has already worked out.

  A hex lock entry carries its own declared children, which is what lets
  `Depdep.Key` compute a whole closure from one file without fetching anything.
  A git entry carries url, ref and opts and stops there — so a git dependency
  cannot be keyed, and the skip propagates to everything above it.

  Mix knows the answer, because `mix deps.get` had to resolve it. Asking is
  sounder than deriving: a `mix.exs` is arbitrary Elixir that may branch on
  `Mix.env()`, read the environment, or call functions defined elsewhere in the
  file, so evaluating one ourselves would move the wrong-restore risk somewhere
  less visible rather than removing it. Here Mix does the evaluating, in the
  project's own context, exactly as it already did.

  `mix deps.tree --format dot` emits the edges and nothing else:

      "plug" -> "mime" [label="~> 1.0 or ~> 2.0"]

  and — measured, with `find _build -name "*.beam"` coming back empty — compiles
  neither the dependencies nor the project. The label is Mix's resolution INPUT,
  not its output; the lock already records what was chosen, so only the edge is
  read.
  """

  @dot "deps_tree.dot"

  @doc """
  `{:ok, %{parent => [child]}}` for a project, or `{:error, reason}`.

  `env` must be the `MIX_ENV` the keys are being computed for: a graph resolved
  under another env differs wherever a dependency is declared `only:`, and a
  wrong child list is a wrong key.
  """
  def read(project_dir, env) do
    cond do
      System.find_executable("mix") == nil ->
        {:error, "no mix on this machine"}

      File.exists?(Path.join(project_dir, @dot)) ->
        # Someone else's file. Overwriting it and then deleting it would be
        # destroying work in a checkout depdep does not own.
        {:error, "#{@dot} already exists in #{project_dir} — leaving it alone"}

      true ->
        generate(project_dir, env)
    end
  end

  defp generate(project_dir, env) do
    path = Path.join(project_dir, @dot)

    result =
      case System.cmd("mix", ["deps.tree", "--format", "dot"],
             cd: project_dir,
             env: [{"MIX_ENV", to_string(env)}],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> read_dot(path)
        {output, status} -> {:error, "mix deps.tree exited #{status}: #{summary(output)}"}
      end

    File.rm(path)
    result
  end

  defp read_dot(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, parse(contents)}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Edges out of a DOT graph, as `%{parent => [child]}`.

  Public because it is the contract with `mix deps.tree` and the only part of
  this testable without a Mix project. Lines that are not edges — the digraph
  header, a bare node, the closing brace — are ignored rather than guessed at.
  """
  def parse(contents) do
    ~r/"(?<parent>[^"]+)"\s*->\s*"(?<child>[^"]+)"/
    |> Regex.scan(contents, capture: :all_names)
    |> Enum.reduce(%{}, fn [child, parent], acc ->
      Map.update(acc, parent, [child], &(&1 ++ [child]))
    end)
    |> Map.new(fn {parent, children} -> {parent, children |> Enum.uniq() |> Enum.sort()} end)
  end

  defp summary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> Kernel.||("no output")
    |> String.slice(0, 200)
  end
end
