defmodule Depdep.ArchiveTest do
  @moduledoc """
  What an object contains.

  Shipping only `_build` restores cleanly and then recompiles everything,
  because Mix compares source mtimes against the build manifest and
  `mix deps.get` writes fresh source. Measured before the fix: 16 of 16
  dependencies restored, 16 re-fetched, 16 recompiled, and a pipeline 9% slower
  than having no store at all. Nothing about that is visible at restore time, so
  it is asserted here.
  """
  use ExUnit.Case, async: true

  test "an object carries deps/ source as well as the _build tree" do
    assert Depdep.Archive.trees("ash", :test) == ["deps/ash", "_build/test/lib/ash"]
  end

  test "a dependency with a build but no source counts as absent" do
    dir = tmp_dir()
    File.mkdir_p!(Path.join(dir, "_build/test/lib/ash"))

    refute Depdep.Archive.complete?(dir, "ash", :test)

    File.mkdir_p!(Path.join(dir, "deps/ash"))
    assert Depdep.Archive.complete?(dir, "ash", :test)
  end

  test "a round trip through an archive restores both trees" do
    source = tmp_dir()
    File.mkdir_p!(Path.join(source, "deps/ash/lib"))
    File.mkdir_p!(Path.join(source, "_build/test/lib/ash/ebin"))
    File.write!(Path.join(source, "deps/ash/lib/ash.ex"), "defmodule Ash do end")
    File.write!(Path.join(source, "_build/test/lib/ash/ebin/Elixir.Ash.beam"), "beam")

    tar = Path.join(System.tmp_dir!(), "depdep-test-#{unique()}.tar.gz")
    assert :ok = Depdep.Archive.create(source, "ash", :test, tar)

    dest = tmp_dir()
    assert :ok = Depdep.Archive.extract(tar, dest)
    File.rm(tar)

    assert Depdep.Archive.complete?(dest, "ash", :test)
    assert File.read!(Path.join(dest, "deps/ash/lib/ash.ex")) == "defmodule Ash do end"
    assert File.read!(Path.join(dest, "_build/test/lib/ash/ebin/Elixir.Ash.beam")) == "beam"
  end

  test "archiving a dependency that is not there is an error, not an empty archive" do
    assert {:error, _} =
             Depdep.Archive.create(
               tmp_dir(),
               "absent",
               :test,
               Path.join(System.tmp_dir!(), "x.tar.gz")
             )
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "depdep-test-#{unique()}")
    File.mkdir_p!(dir)
    on_exit_rm(dir)
    dir
  end

  defp on_exit_rm(dir), do: ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
  defp unique, do: :erlang.unique_integer([:positive])
end
