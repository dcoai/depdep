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

  # #131, from #122/#110/#135. The live store holds three objects for
  # `plug 1.20.3`, carrying `_build/test`, `_build/sqlite/test` and
  # `_build/sqlite/prod` — metresis sets `build_path: "_build/#{db_backend()}"` —
  # and every one records a lock identical to the consumer's. The key has no
  # build-path input and should not have one, since the bytes do not differ, so
  # one object serves projects that build in different places.
  #
  # Extracting in place put the build tree where the consumer's Mix never looks.
  # validate_manifest/1 then read no manifest at opts[:build] and reported "the
  # dependency build is outdated" — the same sentence it uses for a lock
  # mismatch, which is why this took days to find.
  describe "an object built somewhere else restores where THIS member builds" do
    setup do
      base = Path.join(System.tmp_dir!(), "relocate-#{System.unique_integer([:positive])}")
      pusher = Path.join(base, "pusher")
      puller = Path.join(base, "puller")
      on_exit(fn -> File.rm_rf!(base) end)
      %{base: base, pusher: pusher, puller: puller}
    end

    defp build(dir, build_path, name, contents) do
      File.mkdir_p!(Path.join([dir, build_path, "lib", name, ".mix"]))
      File.mkdir_p!(Path.join([dir, "deps", name]))

      File.write!(
        Path.join([dir, build_path, "lib", name, ".mix", "compile.elixir_scm"]),
        contents
      )

      File.write!(Path.join([dir, "deps", name, "mix.exs"]), "source\n")
    end

    @tag verifies: "restore-lands-at-this-members-build-path"
    test "the manifest lands where Mix will read it, not where the pusher put it", ctx do
      # metresis's shape: build_path "_build/sqlite", so the tree is
      # _build/sqlite/test/lib/plug.
      build(ctx.pusher, "_build/sqlite/test", "plug", "the pusher's manifest")
      archive = Path.join(ctx.base, "plug.tar.gz")
      assert :ok = Depdep.Archive.create(ctx.pusher, "plug", "_build/sqlite/test", archive)

      # extc's shape: build_path "_build", so the tree is _build/test/lib/plug.
      trees = Depdep.Archive.trees("plug", "_build/test")
      assert :ok = Depdep.Archive.extract(archive, ctx.puller, trees)

      manifest = Path.join([ctx.puller, "_build/test/lib/plug/.mix/compile.elixir_scm"])
      assert File.read!(manifest) == "the pusher's manifest"
      assert File.exists?(Path.join([ctx.puller, "deps/plug/mix.exs"]))

      # And Depdep.Archive.complete?/3 — which is how a later run decides the unit is
      # already satisfied — agrees, at the consumer's own build path.
      assert Depdep.Archive.complete?(ctx.puller, "plug", "_build/test")
    end

    test "the pusher's build directory is not left behind as junk", ctx do
      build(ctx.pusher, "_build/sqlite/test", "plug", "m")
      archive = Path.join(ctx.base, "plug.tar.gz")
      assert :ok = Depdep.Archive.create(ctx.pusher, "plug", "_build/sqlite/test", archive)

      assert :ok =
               Depdep.Archive.extract(
                 archive,
                 ctx.puller,
                 Depdep.Archive.trees("plug", "_build/test")
               )

      refute File.exists?(Path.join(ctx.puller, "_build/sqlite")),
             "extracting another project's object left its build path behind"

      refute File.exists?(Path.join(ctx.puller, ".depdep")) and
               Path.wildcard(Path.join([ctx.puller, ".depdep", "restore-*"])) != [],
             "the staging directory was not cleaned up"
    end

    test "a same-path restore still works, which is the common case", ctx do
      build(ctx.pusher, "_build/test", "plug", "same path")
      archive = Path.join(ctx.base, "plug.tar.gz")
      assert :ok = Depdep.Archive.create(ctx.pusher, "plug", "_build/test", archive)

      assert :ok =
               Depdep.Archive.extract(
                 archive,
                 ctx.puller,
                 Depdep.Archive.trees("plug", "_build/test")
               )

      assert File.read!(Path.join([ctx.puller, "_build/test/lib/plug/.mix/compile.elixir_scm"])) ==
               "same path"
    end

    # The fail-safe direction: a tree the object does not carry makes the unit a
    # miss, which costs a compile. Leaving it absent would be a wrong restore.
    @tag verifies: "restore-lands-at-this-members-build-path"
    test "an object missing a tree is an error, not a partial restore", ctx do
      File.mkdir_p!(Path.join([ctx.pusher, "deps", "plug"]))
      File.write!(Path.join([ctx.pusher, "deps", "plug", "mix.exs"]), "only source\n")
      archive = Path.join(ctx.base, "plug.tar.gz")
      assert :ok = Depdep.Archive.create_trees(ctx.pusher, ["deps/plug"], archive, "plug")

      assert {:error, reason} =
               Depdep.Archive.extract(
                 archive,
                 ctx.puller,
                 Depdep.Archive.trees("plug", "_build/test")
               )

      assert reason =~ "_build/test/lib/plug"
      refute Depdep.Archive.complete?(ctx.puller, "plug", "_build/test")
    end
  end
end
