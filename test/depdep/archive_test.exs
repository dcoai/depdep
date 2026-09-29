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
    assert Depdep.Archive.trees("ash", "_build/test") == ["deps/ash", "_build/test/lib/ash"]
  end

  @tag verifies: "archive-both-trees"
  test "a dependency with a build but no source counts as absent" do
    dir = tmp_dir()
    File.mkdir_p!(Path.join(dir, "_build/test/lib/ash"))

    refute Depdep.Archive.complete?(dir, "ash", "_build/test")

    File.mkdir_p!(Path.join(dir, "deps/ash"))
    assert Depdep.Archive.complete?(dir, "ash", "_build/test")
  end

  # #98: a git dependency is only restored after `mix deps.get` has cloned it,
  # and git writes its objects read-only. Extracting over them was :eacces on
  # every consumer; a restore replaces the trees it carries.
  test "a restore replaces existing trees, read-only files and leftovers included" do
    source = tmp_dir()
    File.mkdir_p!(Path.join(source, "deps/forked/.git/objects/ab"))
    File.mkdir_p!(Path.join(source, "_build/test/lib/forked/ebin"))
    File.write!(Path.join(source, "deps/forked/.git/objects/ab/cdef"), "archived object")
    File.write!(Path.join(source, "_build/test/lib/forked/ebin/Elixir.Forked.beam"), "beam")
    tar = Path.join(System.tmp_dir!(), "depdep-test-#{unique()}.tar.gz")
    assert :ok = Depdep.Archive.create(source, "forked", "_build/test", tar)

    # The checkout deps.get just made: the same object, read-only, plus a
    # leftover from an earlier build that is not in the archive.
    dest = tmp_dir()
    File.mkdir_p!(Path.join(dest, "deps/forked/.git/objects/ab"))
    File.mkdir_p!(Path.join(dest, "_build/test/lib/forked/ebin"))
    existing = Path.join(dest, "deps/forked/.git/objects/ab/cdef")
    File.write!(existing, "fetched object")
    File.chmod!(existing, 0o444)
    leftover = Path.join(dest, "_build/test/lib/forked/ebin/Elixir.Old.beam")
    File.write!(leftover, "stale")

    assert :ok = Depdep.Archive.extract(tar, dest, Depdep.Archive.trees("forked", "_build/test"))
    File.rm(tar)

    assert File.read!(existing) == "archived object"
    refute File.exists?(leftover)
    assert File.read!(Path.join(dest, "_build/test/lib/forked/ebin/Elixir.Forked.beam")) == "beam"
  end

  test "a round trip through an archive restores both trees" do
    source = tmp_dir()
    File.mkdir_p!(Path.join(source, "deps/ash/lib"))
    File.mkdir_p!(Path.join(source, "_build/test/lib/ash/ebin"))
    File.write!(Path.join(source, "deps/ash/lib/ash.ex"), "defmodule Ash do end")
    File.write!(Path.join(source, "_build/test/lib/ash/ebin/Elixir.Ash.beam"), "beam")

    tar = Path.join(System.tmp_dir!(), "depdep-test-#{unique()}.tar.gz")
    assert :ok = Depdep.Archive.create(source, "ash", "_build/test", tar)

    dest = tmp_dir()
    assert :ok = Depdep.Archive.extract(tar, dest, Depdep.Archive.trees("ash", "_build/test"))
    File.rm(tar)

    assert Depdep.Archive.complete?(dest, "ash", "_build/test")
    assert File.read!(Path.join(dest, "deps/ash/lib/ash.ex")) == "defmodule Ash do end"
    assert File.read!(Path.join(dest, "_build/test/lib/ash/ebin/Elixir.Ash.beam")) == "beam"
  end

  test "archiving a dependency that is not there is an error, not an empty archive" do
    assert {:error, _} =
             Depdep.Archive.create(
               tmp_dir(),
               "absent",
               "_build/test",
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

  # The failure the README documents at 9% slower than having no store at all:
  # `mix deps.get` writes source with fresh mtimes, a restored build manifest
  # looks older than it, Mix finds every dependency stale, and recompiles — a
  # perfect restore followed by a full rebuild.
  #
  # It is also the objection that made a SECOND pull after `deps.get` look
  # impossible, and the reason it does not apply is that an object carries BOTH
  # trees and `:erl_tar` restores recorded mtimes. That is an argument until it
  # is a test.
  describe "restoring over freshly fetched source" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-mtime-#{System.unique_integer([:positive])}")
      source = Path.join([dir, "deps", "forked", "lib"])
      build = Path.join([dir, "_build", "test", "lib", "forked", ".mix"])
      File.mkdir_p!(source)
      File.mkdir_p!(build)
      on_exit(fn -> File.rm_rf!(dir) end)

      source_file = Path.join(source, "forked.ex")
      manifest = Path.join(build, "compile.elixir")
      File.write!(source_file, "defmodule Forked do end")
      File.write!(manifest, "manifest")

      # As at build time: the manifest is written after the source it compiled.
      old = ~N[2026-01-01 00:00:00] |> NaiveDateTime.to_erl()
      newer = ~N[2026-01-01 00:05:00] |> NaiveDateTime.to_erl()
      File.touch!(source_file, old)
      File.touch!(manifest, newer)

      %{dir: dir, source_file: source_file, manifest: manifest}
    end

    test "puts the archived mtimes back, so the manifest stays newer", ctx do
      tmp = Path.join(System.tmp_dir!(), "depdep-mt-#{System.unique_integer([:positive])}.tar.gz")
      on_exit(fn -> File.rm(tmp) end)

      assert Depdep.Archive.create(ctx.dir, "forked", "_build/test", tmp) == :ok

      # What `mix deps.get` does: rewrite the source, now newer than the
      # manifest. Left alone, Mix would call the dependency stale.
      File.write!(ctx.source_file, "defmodule Forked do end")
      File.touch!(ctx.source_file)
      assert mtime(ctx.source_file) > mtime(ctx.manifest)

      assert Depdep.Archive.extract(tmp, ctx.dir, Depdep.Archive.trees("forked", "_build/test")) ==
               :ok

      assert mtime(ctx.source_file) < mtime(ctx.manifest),
             "restoring both trees must put the build back ahead of its source"
    end

    defp mtime(path), do: File.stat!(path, time: :posix).mtime
  end
end
