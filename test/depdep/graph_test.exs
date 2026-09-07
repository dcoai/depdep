defmodule Depdep.GraphTest do
  @moduledoc """
  The contract with `mix deps.tree --format dot`.

  Parsing is exercised directly; the shell-out's guards are exercised through
  `read/2`, which must never raise however unhelpful the environment is.
  """
  use ExUnit.Case, async: true

  alias Depdep.Graph

  @dot """
  digraph "dependency tree" {
    "probe"
    "probe" -> "plug" [label=""]
    "plug" -> "mime" [label="~> 1.0 or ~> 2.0"]
    "plug" -> "plug_crypto" [label="~> 1.1.1 or ~> 1.2 or ~> 2.0"]
    "plug" -> "telemetry" [label="~> 0.4.3 or ~> 1.0"]
  }
  """

  describe "parse/1" do
    # The edge is the whole point: a git lock entry has url, ref and opts and no
    # child list, and this is what supplies the missing link.
    test "reads the edges" do
      assert Graph.parse(@dot) == %{
               "probe" => ["plug"],
               "plug" => ["mime", "plug_crypto", "telemetry"]
             }
    end

    # The label is Mix's resolution INPUT. What was chosen is in the lock, and
    # keying on a requirement rather than a resolution would be wrong.
    test "ignores the version requirement" do
      refute Graph.parse(@dot) |> Map.values() |> List.flatten() |> Enum.any?(&(&1 =~ "~>"))
    end

    test "a bare node contributes nothing" do
      assert Graph.parse(~s(digraph "x" {\n  "lonely"\n})) == %{}
    end

    test "anything that is not a graph is empty rather than an error" do
      assert Graph.parse("") == %{}
      assert Graph.parse("not a graph at all") == %{}
    end

    test "children are sorted and deduplicated, so a graph is a function of its edges" do
      dot = ~s("a" -> "c"\n"a" -> "b"\n"a" -> "b")
      assert Graph.parse(dot) == %{"a" => ["b", "c"]}
    end
  end

  describe "read/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-graph-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    # `--format dot` writes into the current directory rather than stdout. That
    # is someone else's checkout, and clobbering a file that was already there —
    # then deleting it — would be destroying work depdep does not own.
    test "refuses when a deps_tree.dot is already there, and leaves it", %{dir: dir} do
      path = Path.join(dir, "deps_tree.dot")
      File.write!(path, "someone else's file")

      assert {:error, reason} = Graph.read(dir, :test)
      assert reason =~ "already exists"
      assert File.read!(path) == "someone else's file"
    end

    # Every failure here is a missing graph, never a raise: the git dependency
    # then skips exactly as it did before any of this existed.
    test "a directory that is not a Mix project is an error, not a crash", %{dir: dir} do
      assert {:error, _reason} = Graph.read(dir, :test)
      refute File.exists?(Path.join(dir, "deps_tree.dot"))
    end
  end
end
