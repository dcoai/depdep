defmodule Depdep.Provider.MixTest do
  @moduledoc """
  The gating test for the seam: extracting it must not have moved a key.

  An object path is a promise to every consumer's store. If one changes, every
  object already written becomes unreachable and every pipeline silently pays a
  full compile — with nothing failing to say so. So the provider is asserted
  against `Depdep.Key.object/3` directly rather than against itself.

  `async: false`: enumerating a member asks Mix about it (`Depdep.Member`),
  which pushes Mix's global project stack AND changes the VM's working
  directory for the duration. A test in another module that spawns a
  subprocess meanwhile inherits a fixture directory as its cwd, and finds it
  deleted a moment later — seen as `getcwd() failed` inside a git clone in CI.
  """
  use ExUnit.Case, async: false

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

  # #79, the consumer shape: `{:sibling, path: "../sibling"}` declared in a
  # real mix.exs, `sibling` having locked a hex package the member does not
  # declare. Through `keys_for/3` and `enumerate/1`, as a run would.
  describe "a member with a path dependency" do
    setup ctx do
      member = Path.join(ctx.root, "member")
      sibling = Path.join(ctx.root, "sibling")
      File.mkdir_p!(member)
      File.mkdir_p!(sibling)

      File.write!(
        Path.join(sibling, "mix.exs"),
        "defmodule Sib#{System.unique_integer([:positive])}.MixProject do\n  use Mix.Project\n  def project, do: [app: :sibling, version: \"0.1.0\"]\nend\n"
      )

      File.write!(Path.join(member, "mix.exs"), """
      defmodule Member#{System.unique_integer([:positive])}.MixProject do
        use Mix.Project
        def project, do: [app: :member, version: "0.1.0", deps: deps()]
        defp deps, do: [{:jason, "~> 1.4"}, {:sibling, path: "../sibling"}]
      end
      """)

      # sibling's closure is in the member's lock (Mix resolves it there), but
      # nothing in the member declares decimal directly.
      File.write!(Path.join(member, "mix.lock"), """
      %{
        "decimal": {:hex, :decimal, "2.1.1", "innerdec", [:mix], [], "hexpm", "outerdec"},
        "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"}
      }
      """)

      :ok
    end

    test "the closure is ambiguous and requested, and the warning names the path dependency",
         ctx do
      {:ok, keys, _lock, verdicts, unlocked} = Depdep.keys_for(ctx.root, "member", :test)

      assert unlocked == ["sibling"]
      assert verdicts["jason"] == :active
      assert verdicts["decimal"] == :ambiguous
      assert {:key, _} = keys["decimal"]

      {:ok, units, warnings} =
        Provider.Mix.enumerate(root: ctx.root, env: :test, project: "member")

      assert Enum.find(units, &(&1.name == "decimal")).resolution |> elem(0) == :key

      assert warnings == [
               "member: 1 dependencies may be outside MIX_ENV=test but are requested " <>
                 "anyway — sibling is a path dependency whose closure is not in the lock"
             ]
    end
  end

  describe "enumerate/1 produces exactly what the pre-seam path produced" do
    test "every object path matches Depdep.Key.object/3 computed directly", ctx do
      {:ok, keys, lock, _verdicts, _unlocked} = Depdep.keys_for(ctx.root, "app", :test)

      for {name, {:key, hash}} <- keys do
        expected = Depdep.Key.object(name, Map.fetch!(lock, name), hash)
        assert ctx.by_name[name].object == expected
      end
    end

    test "the keys themselves are unchanged", ctx do
      {:ok, keys, _lock, _verdicts, _unlocked} = Depdep.keys_for(ctx.root, "app", :test)

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

  # #58: with a mix.exs to read, a lock entry the env never builds is resolved
  # before any key or network call. The fixture above has no mix.exs, which is
  # why every entry there is still keyed — `Depdep.EnvSet.declared/2` answers
  # `:unknown` and nothing changes.
  describe "enumerate/1 under a MIX_ENV that never builds part of the lock" do
    setup %{root: root} do
      dir = Path.join(root, "envapp")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule DepdepMixEnvFixture#{System.unique_integer([:positive])}.MixProject do
        use Mix.Project
        def project, do: [app: :depdep_mix_env_fixture, version: "0.1.0", deps: deps()]
        defp deps, do: [{:jason, "~> 1.4"}, {:ex_doc, "~> 0.34", only: :dev}]
      end
      """)

      File.write!(Path.join(dir, "mix.lock"), """
      %{
        "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"},
        "ex_doc": {:hex, :ex_doc, "0.34.0", "innerexdoc", [:mix], [{:makeup, "~> 1.0", [hex: :makeup, repo: "hexpm", optional: false]}], "hexpm", "outerexdoc"},
        "makeup": {:hex, :makeup, "1.1.0", "innermakeup", [:mix], [], "hexpm", "outermakeup"}
      }
      """)

      :ok
    end

    test "the dev-only chain is not_for_env under test, with no object and no detail", %{
      root: root
    } do
      {:ok, units, warnings} = Provider.Mix.enumerate(root: root, env: :test, project: "envapp")
      by_name = Map.new(units, &{&1.name, &1})

      assert warnings == []
      assert {:key, _} = by_name["jason"].resolution
      assert by_name["ex_doc"].resolution == {:not_for_env, :test}
      assert by_name["makeup"].resolution == {:not_for_env, :test}
      assert by_name["ex_doc"].object == nil
      assert by_name["ex_doc"].detail == "-"
      refute Provider.Mix.present?(by_name["ex_doc"])
    end

    test "the same chain is keyed under dev", %{root: root} do
      {:ok, units, _} = Provider.Mix.enumerate(root: root, env: :dev, project: "envapp")
      assert Enum.all?(units, &match?({:key, _}, &1.resolution))
    end

    # Before deps.get a git dependency's children are unknown, so the walk cannot
    # prove the chain is outside the env. It is requested as before, and the
    # reader of `missing N` is told why part of it may never become a hit.
    test "a git dependency with unknown children keeps the rest requested, with one warning", %{
      root: root
    } do
      dir = Path.join(root, "envapp")

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule DepdepMixEnvFixtureGit#{System.unique_integer([:positive])}.MixProject do
        use Mix.Project
        def project, do: [app: :depdep_mix_env_fixture_git, version: "0.1.0", deps: deps()]
        defp deps, do: [{:jason, "~> 1.4"}, {:forked, git: "https://example.invalid/forked.git"}, {:ex_doc, "~> 0.34", only: :dev}]
      end
      """)

      lock = File.read!(Path.join(dir, "mix.lock"))

      File.write!(
        Path.join(dir, "mix.lock"),
        String.replace(
          lock,
          "%{",
          ~s(%{\n  "forked": {:git, "https://example.invalid/forked.git", "88ab3a0d", []},)
        )
      )

      {:ok, units, warnings} = Provider.Mix.enumerate(root: root, env: :test, project: "envapp")
      by_name = Map.new(units, &{&1.name, &1})

      assert {:key, _} = by_name["ex_doc"].resolution
      assert [warning] = warnings
      assert warning =~ "2 dependencies may be outside MIX_ENV=test"
      assert warning =~ "before deps.get"
    end

    # A unit that is never fetched must not be listed as wanted, or the sweep
    # would keep objects for it that will never exist.
    test "a not_for_env unit contributes nothing to the root", %{root: root} do
      {:ok, units, _} = Provider.Mix.enumerate(root: root, env: :test, project: "envapp")
      paths = units |> Enum.map(& &1.object) |> Enum.reject(&is_nil/1)
      assert length(paths) == 1
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

    test "present? needs the key recorded, not just the trees", %{unit: unit} do
      refute Provider.Mix.present?(unit), "trees alone are not proof the tree is current"

      assert Provider.Mix.record(unit) == :ok
      assert Provider.Mix.present?(unit)
    end

    # Half a dependency is worse than none: Mix would treat the restored build
    # as current and then recompile the moment `deps.get` refreshed the source.
    test "present? is false when only the build tree survives", %{dir: dir, unit: unit} do
      assert Provider.Mix.record(unit) == :ok
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
      assert Provider.Mix.record(unit) == :ok
      assert Provider.Mix.present?(unit)
      assert File.read!(Path.join([dir, "deps", "jason", "lib", "jason.ex"])) == "source"

      assert File.read!(Path.join([dir, "_build", "test", "lib", "jason", "ebin", "j.beam"])) ==
               "beam"
    end

    # The note must not travel inside the object. If it did, `collect/2` would be
    # writing into a tree it is only supposed to read, and a stored object would
    # differ from what `mix compile` produces.
    test "the recorded key is never tarred into the object", %{unit: unit} do
      tmp = Path.join(System.tmp_dir!(), "depdep-nt-#{System.unique_integer([:positive])}.tar.gz")
      on_exit(fn -> File.rm(tmp) end)

      assert Provider.Mix.record(unit) == :ok
      assert Provider.Mix.collect(unit, tmp) == :ok

      {:ok, entries} = :erl_tar.table(String.to_charlist(tmp), [:compressed])
      names = Enum.map(entries, &to_string/1)

      refute Enum.any?(names, &String.contains?(&1, ".depdep")), inspect(names)
    end
  end

  # The defect this work item exists for, from dco-tek/bizex: an `ash` bump over
  # a warm `_build` left both directories in place, so the pull was skipped, and
  # Mix recompiled against source it had just fetched — while the right object
  # sat in the store, unrequested.
  describe "a stale tree" do
    setup %{root: root, by_name: by_name} do
      dir = Path.join(root, "app")
      File.mkdir_p!(Path.join([dir, "deps", "jason"]))
      File.mkdir_p!(Path.join([dir, "_build", "test", "lib", "jason"]))
      %{dir: dir, unit: by_name["jason"]}
    end

    test "is not treated as present when the recorded key is a different one", ctx do
      note = Path.join([ctx.dir, "_build", "test", ".depdep"])
      File.mkdir_p!(note)
      File.write!(Path.join(note, "jason"), "the key of some earlier version")

      refute Provider.Mix.present?(ctx.unit)
    end

    # The first run after this shipped: no notes exist anywhere yet, so every
    # dependency is fetched once. Safe direction, and cheap — they are all hits.
    test "is not treated as present when nothing was recorded", ctx do
      refute Provider.Mix.present?(ctx.unit)
    end
  end

  # `present?/1` feeds BOTH directions, and a push must not consider the key: a
  # locally built tree that was never restored has no note, and requiring one
  # would make `--push` report `not built here` for everything and upload
  # nothing, forever, silently.
  describe "the push direction" do
    setup %{root: root} do
      dir = Path.join(root, "app")
      File.mkdir_p!(Path.join([dir, "deps", "jason"]))
      File.mkdir_p!(Path.join([dir, "_build", "test", "lib", "jason"]))

      {:ok, units, []} =
        Provider.Mix.enumerate(root: root, env: :test, project: "app", direction: :push)

      %{unit: Enum.find(units, &(&1.name == "jason"))}
    end

    test "offers a locally built tree that was never restored", %{unit: unit} do
      assert Provider.Mix.present?(unit)
    end
  end

  describe "record/1" do
    test "is a no-op for a dependency that cannot be keyed", %{by_name: by_name} do
      assert Provider.Mix.record(by_name["forked"]) == :ok
    end
  end
end
