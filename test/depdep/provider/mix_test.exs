defmodule Depdep.Provider.MixTest do
  @moduledoc """
  The gating test for the seam: extracting it must not have moved a key.

  An object path is a promise to every consumer's store. If one changes, every
  object already written becomes unreachable and every pipeline silently pays a
  full compile — with nothing failing to say so. So the provider is asserted
  against `Depdep.Key.object/3` directly rather than against itself.
  """
  use ExUnit.Case, async: true

  alias Depdep.{Provider, Unit}

  @lock """
  %{
    "decimal": {:hex, :decimal, "2.1.1", "innerdec", [:mix], [], "hexpm", "outerdec"},
    "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [{:decimal, "~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "outerjason"},
    "forked": {:git, "https://example.invalid/forked.git", "88ab3a0d", [tag: "v2.1.1"]}
  }
  """

  setup do
    root = Path.join(System.tmp_dir!(), "depdep-mix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "app"))
    File.write!(Path.join([root, "app", "mix.lock"]), @lock)
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [root: root, env: :test, project: "app"]
    {:ok, units, warnings} = Provider.Mix.enumerate(opts)

    %{
      root: root,
      opts: opts,
      units: units,
      warnings: warnings,
      by_name: Map.new(units, &{&1.name, &1})
    }
  end

  describe "enumerate/1 produces exactly what the pre-seam path produced" do
    test "every object path matches Depdep.Key.object/3 computed directly", ctx do
      {:ok, keys, lock} = Depdep.keys_for(ctx.root, "app", :test)

      for {name, {:key, hash}} <- keys do
        expected = Depdep.Key.object(name, Map.fetch!(lock, name), hash)
        assert ctx.by_name[name].object == expected
      end
    end

    test "the keys themselves are unchanged", ctx do
      {:ok, keys, _lock} = Depdep.keys_for(ctx.root, "app", :test)

      for {name, resolution} <- keys do
        assert ctx.by_name[name].resolution == resolution
      end
    end

    test "a unit is emitted for every entry in the lock, and no others", ctx do
      assert Enum.sort(Map.keys(ctx.by_name)) == ["decimal", "forked", "jason"]
    end
  end

  describe "enumerate/1" do
    test "groups by project so a poncho's members stay distinguishable", ctx do
      assert Enum.all?(ctx.units, &(&1.group == "app"))
      assert Unit.label(ctx.by_name["jason"]) == "app/jason"
    end

    test "carries the version for the plan's detail column", ctx do
      assert ctx.by_name["jason"].detail == "1.4.4"
    end

    # A git dependency cannot be keyed, so it has no object to name and no
    # version column to fill. Reporting it as skipped is the fail-safe
    # direction: it costs a compile, never a wrong restore.
    test "an unkeyable dependency has no object and no detail", ctx do
      unit = ctx.by_name["forked"]

      assert {:skip, reason} = unit.resolution
      assert reason =~ "git"
      assert unit.object == nil
      assert unit.detail == "-"
    end

    test "a project that cannot be read is a warning, not an error", %{root: root} do
      {:ok, units, warnings} = Provider.Mix.enumerate(root: root, env: :test, project: "absent")

      assert units == []
      assert [warning] = warnings
      assert warning =~ "absent"
      assert warning =~ "every dependency will be compiled"
    end

    # One unreadable member of a poncho must not cost the other ten their
    # restore, so enumeration continues past it.
    test "one unreadable project does not suppress a readable one", %{root: root} do
      {:ok, units, warnings} =
        Provider.Mix.enumerate(root: root, env: :test, project: "absent", project: "app")

      assert length(warnings) == 1
      assert Enum.any?(units, &(&1.name == "jason"))
    end
  end

  describe "present?/restore/collect round-trip" do
    setup %{root: root, by_name: by_name} do
      dir = Path.join(root, "app")
      File.mkdir_p!(Path.join([dir, "deps", "jason", "lib"]))
      File.mkdir_p!(Path.join([dir, "_build", "test", "lib", "jason", "ebin"]))
      File.write!(Path.join([dir, "deps", "jason", "lib", "jason.ex"]), "source")
      File.write!(Path.join([dir, "_build", "test", "lib", "jason", "ebin", "j.beam"]), "beam")
      %{dir: dir, unit: by_name["jason"]}
    end

    test "present? sees both trees", %{unit: unit} do
      assert Provider.Mix.present?(unit)
    end

    # Half a dependency is worse than none: Mix would treat the restored build
    # as current and then recompile the moment `deps.get` refreshed the source.
    test "present? is false when only the build tree survives", %{dir: dir, unit: unit} do
      File.rm_rf!(Path.join([dir, "deps", "jason"]))
      refute Provider.Mix.present?(unit)
    end

    test "collect then restore reproduces both trees", %{dir: dir, unit: unit} do
      tmp = Path.join(System.tmp_dir!(), "depdep-rt-#{System.unique_integer([:positive])}.tar.gz")
      on_exit(fn -> File.rm(tmp) end)

      assert Provider.Mix.collect(unit, tmp) == :ok

      File.rm_rf!(Path.join([dir, "deps", "jason"]))
      File.rm_rf!(Path.join([dir, "_build", "test", "lib", "jason"]))
      refute Provider.Mix.present?(unit)

      assert Provider.Mix.restore(unit, tmp) == :ok
      assert Provider.Mix.present?(unit)
      assert File.read!(Path.join([dir, "deps", "jason", "lib", "jason.ex"])) == "source"

      assert File.read!(Path.join([dir, "_build", "test", "lib", "jason", "ebin", "j.beam"])) ==
               "beam"
    end
  end
end
