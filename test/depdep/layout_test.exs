defmodule Depdep.LayoutTest do
  @moduledoc "Which projects depdep operates on, and how little has to be said."
  use ExUnit.Case, async: true

  alias Depdep.Layout

  describe "a single Mix project" do
    # The case nearly every repository is, and the regression that matters most:
    # a root project with nothing beneath it must keep needing no configuration.
    test "needs no configuration at all" do
      root = tmp_dir()
      File.write!(Path.join(root, "mix.exs"), "")

      assert Layout.projects(root) == {["."], []}
    end

    # The no-lock rule applies to DISCOVERED members, not to a root you pointed
    # depdep at. A dependency-free single project has no lock and is still that
    # project.
    test "is still a project with no lockfile of its own" do
      root = tmp_dir()
      File.write!(Path.join(root, "mix.exs"), "")

      assert {["."], []} = Layout.projects(root)
    end
  end

  describe "a poncho" do
    test "discovers every member" do
      root = tmp_dir()
      for m <- ["platform/crm", "hosts/app"], do: write_project(root, m)

      assert Layout.projects(root) == {["hosts/app", "platform/crm"], []}
    end

    # dco-tek/agentronic's shape: a root coordinator project alongside its
    # members. Before this was handled, the root's mix.exs short-circuited
    # discovery and all 38 members were silently ignored — a --pull that
    # reported a few hits and looked like it had worked.
    test "with a root coordinator project, the root joins its members" do
      root = tmp_dir()
      write_project(root, ".")
      for m <- ["maatronic/store", "tools/cli"], do: write_project(root, m)

      assert Layout.projects(root) == {[".", "maatronic/store", "tools/cli"], []}
    end

    test "discovers members nested several levels deep" do
      root = tmp_dir()
      for m <- ["a", "b/c", "d/e/f"], do: write_project(root, m)

      assert {["a", "b/c", "d/e/f"], []} = Layout.projects(root)
    end

    # A dependency's own mix.exs is not a member.
    test "deps/ and _build/ are never members" do
      root = tmp_dir()
      write_project(root, "platform/crm")
      write_project(root, "platform/crm/deps/jason")
      write_project(root, "platform/crm/_build/test/lib/jason")

      assert Layout.projects(root) == {["platform/crm"], []}
    end
  end

  describe "a mix.exs without a mix.lock" do
    # There is nothing to key without a lock, so such a directory has no objects
    # either way. In agentronic this is what separates the 38 buildable members
    # from the 14 path dependencies a parent compiles.
    test "is not a member" do
      root = tmp_dir()
      write_project(root, "buildable")
      File.mkdir_p!(Path.join(root, "path_dep"))
      File.write!(Path.join([root, "path_dep", "mix.exs"]), "")

      assert {["buildable"], _notes} = Layout.projects(root)
    end

    # Excluded, but never silently: before this rule such a directory WAS a
    # member and produced a per-run warning. Nothing may become invisible.
    test "is reported, once, with a count" do
      root = tmp_dir()
      write_project(root, "buildable")

      for d <- ["one", "two", "three"] do
        File.mkdir_p!(Path.join(root, d))
        File.write!(Path.join([root, d, "mix.exs"]), "")
      end

      assert {["buildable"], [note]} = Layout.projects(root)
      assert note =~ "3 directories have"
      assert note =~ "no mix.lock"
    end

    test "reports one directory in the singular" do
      root = tmp_dir()
      write_project(root, "buildable")
      File.mkdir_p!(Path.join(root, "lone"))
      File.write!(Path.join([root, "lone", "mix.exs"]), "")

      assert {_projects, [note]} = Layout.projects(root)
      assert note =~ "1 directory has"
    end
  end

  describe "--exclude" do
    test "drops a top-level directory, for a member on a different toolchain" do
      root = tmp_dir()
      for m <- ["platform/crm", "clients/wasm"], do: write_project(root, m)

      assert Layout.projects(root, exclude: "clients") == {["platform/crm"], []}
    end

    # A toolchain varies per member, not per top-level group, so a three-deep
    # sub-poncho must be excludable below its top level.
    test "drops a nested subtree without taking its siblings" do
      root = tmp_dir()
      for m <- ["logic-analyzer/core", "logic-analyzer/eval"], do: write_project(root, m)

      assert Layout.projects(root, exclude: "logic-analyzer/eval") ==
               {["logic-analyzer/core"], []}
    end

    # The reason a prefix is matched segment-wise rather than as a string: a
    # partial-segment match would drop a member nobody asked to exclude.
    @tag verifies: "layout-segment-boundaries"
    test "matches whole segments, so `tools` does not drop `tools_vendor`" do
      root = tmp_dir()
      for m <- ["tools/cli", "tools_vendor/x"], do: write_project(root, m)

      assert Layout.projects(root, exclude: "tools") == {["tools_vendor/x"], []}
    end
  end

  test "explicitly named projects win over discovery" do
    root = tmp_dir()
    for m <- ["platform/crm", "hosts/app"], do: write_project(root, m)

    assert Layout.projects(root, project: "hosts/app") == {["hosts/app"], []}
  end

  # Writes a lock as well as a mix.exs, because a mix.exs alone is no longer a
  # member — see the "without a mix.lock" tests above, which exercise that path
  # directly so this helper cannot mask it.
  defp write_project(root, dir) do
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "mix.exs"]), "")
    File.write!(Path.join([root, dir, "mix.lock"]), "%{}")
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "depdep-layout-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
