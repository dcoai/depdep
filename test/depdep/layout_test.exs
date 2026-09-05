defmodule Depdep.LayoutTest do
  @moduledoc "Which projects depdep operates on, and how little has to be said."
  use ExUnit.Case, async: true

  test "a single Mix project needs no configuration at all" do
    root = tmp_dir()
    File.write!(Path.join(root, "mix.exs"), "")

    assert Depdep.Layout.projects(root) == ["."]
  end

  test "a poncho discovers every member" do
    root = tmp_dir()
    for m <- ["platform/crm", "hosts/app"], do: write_project(root, m)

    assert Depdep.Layout.projects(root) == ["hosts/app", "platform/crm"]
  end

  # A dependency's own mix.exs is not a member.
  test "deps/ and _build/ are never members" do
    root = tmp_dir()
    write_project(root, "platform/crm")
    write_project(root, "platform/crm/deps/jason")
    write_project(root, "platform/crm/_build/test/lib/jason")

    assert Depdep.Layout.projects(root) == ["platform/crm"]
  end

  test "a scope can be excluded, for a member on a different toolchain" do
    root = tmp_dir()
    for m <- ["platform/crm", "clients/wasm"], do: write_project(root, m)

    assert Depdep.Layout.projects(root, exclude: "clients") == ["platform/crm"]
  end

  test "explicitly named projects win over discovery" do
    root = tmp_dir()
    for m <- ["platform/crm", "hosts/app"], do: write_project(root, m)

    assert Depdep.Layout.projects(root, project: "hosts/app") == ["hosts/app"]
  end

  defp write_project(root, dir) do
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "mix.exs"]), "")
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "depdep-layout-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
