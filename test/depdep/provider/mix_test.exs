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
  # declare. Under #89 the path dependency is in Mix's list like anything
  # else, with its children, so once the hex packages are fetched its closure
  # is active — by construction, no walk.
  describe "a member with a path dependency" do
    setup ctx do
      member = Path.join(ctx.root, "member")
      sibling = Path.join(ctx.root, "sibling")
      File.mkdir_p!(member)
      File.mkdir_p!(sibling)

      File.write!(Path.join(sibling, "mix.exs"), """
      defmodule Sib#{System.unique_integer([:positive])}.MixProject do
        use Mix.Project
        def project, do: [app: :sibling, version: "0.1.0", deps: [{:decimal, "~> 2.0"}]]
      end
      """)

      File.write!(Path.join(member, "mix.exs"), """
      defmodule Member#{System.unique_integer([:positive])}.MixProject do
        use Mix.Project
        def project, do: [app: :member, version: "0.1.0", deps: deps()]
        defp deps, do: [{:jason, "~> 1.4"}, {:sibling, path: "../sibling"}, {:ex_doc, "~> 0.34", only: :dev}]
      end
      """)

      File.write!(Path.join(member, "mix.lock"), """
      %{
        "decimal": {:hex, :decimal, "2.1.1", "innerdec", [:mix], [], "hexpm", "outerdec"},
        "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"},
        "ex_doc": {:hex, :ex_doc, "0.34.0", "innerexdoc", [:mix], [], "hexpm", "outerexdoc"}
      }
      """)

      for name <- ~w(jason decimal ex_doc) do
        File.mkdir_p!(Path.join([member, "deps", name]))

        File.write!(Path.join([member, "deps", name, "mix.exs"]), """
        defmodule Fetched#{name}#{System.unique_integer([:positive])}.MixProject do
          use Mix.Project
          def project, do: [app: :#{name}, version: "1.0.0"]
        end
        """)
      end

      :ok
    end

    test "the path dependency's closure is active and keyed; the dev-only dependency is not",
         ctx do
      {:ok, keys, deps} = Depdep.keys_for(ctx.root, "member", :test)

      assert deps["decimal"].active? == true
      assert deps["jason"].active? == true
      assert deps["ex_doc"].active? == false
      refute Map.has_key?(deps, "sibling")
      assert {:key, _} = keys["decimal"]

      {:ok, units, warnings} =
        Provider.Mix.enumerate(root: ctx.root, env: :test, project: "member")

      by_name = Map.new(units, &{&1.name, &1})
      assert {:key, _} = by_name["decimal"].resolution
      assert by_name["ex_doc"].resolution == {:not_for_env, :test}
      assert warnings == []
    end
  end

  describe "enumerate/1 produces exactly what the pre-seam path produced" do
    test "every object path matches Depdep.Key.object/3 computed directly", ctx do
      {:ok, keys, deps} = Depdep.keys_for(ctx.root, "app", :test)

      for {name, {:key, hash}} <- keys do
        expected = Depdep.Key.object(name, deps[name].entry, hash)
        assert ctx.by_name[name].object == expected
      end
    end

    test "the keys themselves are unchanged", ctx do
      {:ok, keys, _deps} = Depdep.keys_for(ctx.root, "app", :test)

      for {name, resolution} <- keys do
        assert ctx.by_name[name].resolution == resolution
      end
    end

    # The gate stays strict and gets stricter: a BUILD unit for every lock entry and no
    # others, asserted apart from the source units #164 added. Loosening this to a
    # superset check would have let an unintended extra build unit through, which is the
    # change this test exists to catch — one build unit per entry is what the object
    # paths are a promise about.
    @tag verifies: "spec/05-units-and-providers.md#mix"
    test "a build unit is emitted for every entry in the lock, and no others", ctx do
      build_units =
        ctx.by_name
        |> Map.keys()
        |> Enum.reject(&String.ends_with?(&1, " (source)"))
        |> Enum.sort()

      assert build_units == ["decimal", "forked", "jason"]
    end

    # One source unit, for the one git entry — a hex entry has no source object (#163).
    test "a source unit is emitted for each git entry, and only those", ctx do
      sources =
        ctx.by_name
        |> Map.keys()
        |> Enum.filter(&String.ends_with?(&1, " (source)"))
        |> Enum.sort()

      assert sources == ["forked (source)"]
    end
  end

  describe "enumerate/1" do
    @tag verifies: "spec/05-units-and-providers.md#unit"
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

      %{dir: dir}
    end

    # What `mix deps.get` leaves that Mix reads: a `mix.exs` per dependency.
    # With one, Mix calls the dependency available and lists its children.
    defp fetched(dir, names) do
      for name <- names do
        File.mkdir_p!(Path.join([dir, "deps", name]))

        File.write!(Path.join([dir, "deps", name, "mix.exs"]), """
        defmodule Fetched#{name}#{System.unique_integer([:positive])}.MixProject do
          use Mix.Project
          def project, do: [app: :#{name}, version: "1.0.0"]
        end
        """)
      end
    end

    # After deps.get Mix's list is complete, and a lock entry not in it is
    # outside the env — by Mix's own `only:` rule, not a walk of the lock (#89).
    test "the dev-only chain is not_for_env under test once fetched, with no object and no detail",
         %{root: root, dir: dir} do
      fetched(dir, ~w(jason ex_doc makeup))
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

    test "the same chain is keyed under dev", %{root: root, dir: dir} do
      fetched(dir, ~w(jason ex_doc makeup))
      {:ok, units, _} = Provider.Mix.enumerate(root: root, env: :test, project: "envapp")
      assert Enum.any?(units, &match?({:not_for_env, _}, &1.resolution))

      {:ok, units, _} = Provider.Mix.enumerate(root: root, env: :dev, project: "envapp")
      assert Enum.all?(units, &match?({:key, _}, &1.resolution))
    end

    # Before deps.get Mix's list is incomplete — a hex dependency's children
    # are read from its mix.exs, which is not there — so nothing is called
    # inactive: everything is requested, said once, and the second pass
    # settles it. The fail-safe direction, as before, without the walk.
    test "before deps.get everything is requested, with one warning naming the second pass",
         %{root: root} do
      {:ok, units, warnings} = Provider.Mix.enumerate(root: root, env: :test, project: "envapp")

      assert Enum.all?(units, &match?({:key, _}, &1.resolution))
      assert [warning] = warnings
      assert warning =~ "envapp: dependencies not fetched yet, so 3 lock entries are requested"
      assert warning =~ "--mix-get settles that after deps.get"
    end

    # A git dependency not yet fetched has children Mix cannot read, so its
    # cone stays unknown and it is skipped; nothing else changes.
    test "an unfetched git dependency is skipped and the rest requested", %{root: root, dir: dir} do
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

      assert {:skip, reason} = by_name["forked"].resolution
      assert reason =~ "git"
      assert {:key, _} = by_name["ex_doc"].resolution
      assert [warning] = warnings
      assert warning =~ "4 lock entries are requested"
    end

    # A unit that is never fetched must not be listed as wanted, or the sweep
    # would keep objects for it that will never exist.
    test "a not_for_env unit contributes nothing to the root", %{root: root, dir: dir} do
      fetched(dir, ~w(jason ex_doc makeup))
      {:ok, units, _} = Provider.Mix.enumerate(root: root, env: :test, project: "envapp")
      paths = units |> Enum.map(& &1.object) |> Enum.reject(&is_nil/1)
      assert length(paths) == 1
    end
  end

  # #123: Mix compares the lock's URL against the restored checkout's
  # `remote.origin.url` as STRINGS, and a restored checkout carries the pusher's.
  # Asserted against `Mix.SCM.Git.lock_status/1` itself rather than against a
  # restatement of it, so the test fails if Mix ever changes the comparison.
  describe "a restored git dependency adopts this consumer's origin (#123)" do
    @pusher_url "ssh://git@example.invalid:2022/forked.git"
    @consumer_url "https://example.invalid/forked.git"

    setup do
      root = Path.join(System.tmp_dir!(), "depdep-origin-#{System.unique_integer([:positive])}")
      dir = Path.join(root, "app")
      checkout = Path.join([dir, "deps", "forked"])
      File.mkdir_p!(checkout)
      File.mkdir_p!(Path.join([dir, "_build", "test", "lib", "forked", "ebin"]))
      File.write!(Path.join([dir, "_build", "test", "lib", "forked", "ebin", "f.beam"]), "beam")
      File.write!(Path.join(checkout, "mix.exs"), "source")
      on_exit(fn -> File.rm_rf!(root) end)

      # A real repository, so `git` and Mix both read it for real. Its origin is
      # the PUSHER's spelling — what travels inside an object.
      git = fn args ->
        {_, 0} = System.cmd("git", ["-C", checkout | args], stderr_to_stdout: true)
      end

      git.(["init", "--quiet"])
      git.(["config", "user.email", "t@example.invalid"])
      git.(["config", "user.name", "t"])
      git.(["add", "mix.exs"])
      git.(["commit", "--quiet", "-m", "c"])
      git.(["remote", "add", "origin", @pusher_url])
      {sha, 0} = System.cmd("git", ["-C", checkout, "rev-parse", "HEAD"])
      sha = String.trim(sha)

      # ...while THIS consumer locks the same commit under a different spelling.
      File.write!(
        Path.join(dir, "mix.lock"),
        ~s|%{"forked": {:git, "#{@consumer_url}", "#{sha}", []}}\n|
      )

      {:ok, units, _warnings} =
        Provider.Mix.enumerate(root: root, env: :test, project: "app")

      unit = Enum.find(units, &(&1.name == "forked"))

      %{dir: dir, checkout: checkout, unit: unit, sha: sha}
    end

    defp origin_of(checkout) do
      {url, 0} = System.cmd("git", ["-C", checkout, "config", "remote.origin.url"])
      String.trim(url)
    end

    # The exact opts Mix builds for a git dependency, so `lock_status/1` takes the
    # same path it takes in a real `mix deps` run.
    defp mix_opts(checkout, url, sha),
      do: [git: url, lock: {:git, url, sha, []}, checkout: checkout]

    test "the lock URL reaches the unit", %{unit: unit} do
      assert unit.context.git_origin == @consumer_url
    end

    @tag verifies: "restored-git-origin-adopted"
    test "Mix refuses the pusher's origin, and accepts it after a restore",
         %{dir: dir, checkout: checkout, unit: unit, sha: sha} do
      # The URL Mix compares is read from the lock by `Depdep.Lock.repo/1` — the
      # same reader the restore uses — rather than restated as a literal here.
      lock_url = Depdep.Lock.repo({:git, @consumer_url, sha, []})
      assert lock_url == unit.context.git_origin

      opts = mix_opts(checkout, lock_url, sha)

      # The control: this is the failure consumers saw. Without it, the assertion
      # below could pass because Mix accepts anything.
      assert Mix.SCM.Git.lock_status(opts) == :mismatch
      assert origin_of(checkout) == @pusher_url

      tmp =
        Path.join(System.tmp_dir!(), "depdep-origin-#{System.unique_integer([:positive])}.tar.gz")

      on_exit(fn -> File.rm(tmp) end)
      assert Provider.Mix.collect(unit, tmp) == :ok

      File.rm_rf!(checkout)
      File.rm_rf!(Path.join([dir, "_build", "test", "lib", "forked"]))

      assert Provider.Mix.restore(unit, tmp) == :ok
      assert origin_of(checkout) == @consumer_url
      assert Mix.SCM.Git.lock_status(opts) == :ok
    end

    test "a git object whose checkout has no .git restores without failing",
         %{dir: dir, checkout: checkout, unit: unit} do
      File.rm_rf!(Path.join(checkout, ".git"))

      tmp =
        Path.join(System.tmp_dir!(), "depdep-origin-#{System.unique_integer([:positive])}.tar.gz")

      on_exit(fn -> File.rm(tmp) end)
      assert Provider.Mix.collect(unit, tmp) == :ok
      File.rm_rf!(checkout)
      File.rm_rf!(Path.join([dir, "_build", "test", "lib", "forked"]))

      # Nothing to point anywhere. Mix reads no origin and rebuilds, which
      # `Depdep.RestoreCheck` turns into a miss — a compile, not a wrong restore.
      assert Provider.Mix.restore(unit, tmp) == :ok
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
    @tag verifies: "spec/05-units-and-providers.md#mix"
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
