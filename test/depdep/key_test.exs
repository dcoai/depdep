defmodule Depdep.KeyTest do
  @moduledoc """
  The design arguments, executable.

  Each test names the failure it prevents, because a key function that silently
  stops distinguishing two builds is exactly the defect that produces a wrong
  restore — and a wrong restore is invisible. One measured in `dco-tek/bizex`
  compiled in 2.3 s and passed 106/106 tests while `Ash.Type.File.Source`
  resolved to `Any`.
  """
  use ExUnit.Case, async: true

  import Depdep.LockFixture

  describe "the recursion" do
    # The same ash version compiles to 1317 / 1319 / 1323 beams depending on
    # whether plug and igniter are resolved, because ash guards whole source
    # files on `Code.ensure_loaded?`. Absence must therefore be part of the key,
    # or the two builds collide and one consumer silently gets the other's.
    test "an unresolved optional dependency keys differently from a resolved one" do
      without = [hex("ash", "3.32.3", [{"plug", true}])]
      with_plug = [hex("ash", "3.32.3", [{"plug", true}]), hex("plug", "1.16.0", [])]

      refute key(without, "ash") == key(with_plug, "ash")
    end

    # Why the hash must recurse: spark's macros expand INTO ash's beams, so a
    # spark bump changes ash's correct output while ash's own version and
    # checksum do not move at all.
    test "bumping a child changes the parent's key" do
      before = [hex("ash", "3.32.3", ["spark"]), hex("spark", "2.6.0", [])]
      later = [hex("ash", "3.32.3", ["spark"]), hex("spark", "2.7.0", [])]

      refute key(before, "ash") == key(later, "ash")
    end

    # Why the hash must recurse rather than cover the whole lockfile: precision.
    # A whole-lock digest would invalidate every package on any change at all.
    test "bumping an unrelated dependency leaves a key alone" do
      before = [
        hex("ash", "3.32.3", ["spark"]),
        hex("spark", "2.6.0", []),
        hex("postgrex", "0.20.0", [])
      ]

      later = [
        hex("ash", "3.32.3", ["spark"]),
        hex("spark", "2.6.0", []),
        hex("postgrex", "0.21.0", [])
      ]

      assert key(before, "ash") == key(later, "ash")
    end
  end

  describe "compile-time configuration" do
    # `@setting Application.get_env(:foo, :bar)` at module level is baked in at
    # compile time with no tracking whatsoever — unlike compile_env/2, which at
    # least raises at boot. So config is an input.
    test "config for an app in the closure changes the key" do
      lock = [hex("ash", "3.32.3", ["spark"]), hex("spark", "2.6.0", [])]
      tuned = %{"spark" => Depdep.Key.digest(["formatter: true"])}

      refute key(lock, "ash", %{}) == key(lock, "ash", tuned)
    end

    # The other half of per-app slicing: config for an app OUTSIDE the closure
    # must not move the key, or a project-wide config digest would differ
    # everywhere and no two consumers would ever share an object.
    test "config for an app outside the closure leaves the key alone" do
      lock = [
        hex("ash", "3.32.3", ["spark"]),
        hex("spark", "2.6.0", []),
        hex("swoosh", "1.19.0", [])
      ]

      tuned = %{"swoosh" => Depdep.Key.digest(["adapter: Test"])}

      assert key(lock, "ash", %{}) == key(lock, "ash", tuned)
    end

    test "an unconfigured app and an app configured to [] digest the same" do
      empty = Depdep.Key.digest([inspect([])])
      assert Depdep.Config.digest_for(%{}, "spark") == empty
      assert Depdep.Config.digest_for(%{"spark" => empty}, "spark") == empty
    end
  end

  describe "what cannot be keyed" do
    # A git entry records url, ref and opts — no dependency list — so its closure
    # cannot be known here and it must not be keyed.
    test "a git dependency is skipped rather than guessed at" do
      assert {:skip, _} = key([git("heroicons")], "heroicons")
    end

    test "a dependency on an unkeyable dependency is itself unkeyable" do
      lock = [hex("thing", "1.0.0", ["heroicons"]), git("heroicons")]
      assert {:skip, _} = key(lock, "thing")
    end

    test "a cycle is reported rather than looping forever" do
      lock = Map.new([hex("a", "1.0.0", ["b"]), hex("b", "1.0.0", ["a"])])
      assert {:error, {:cycle, _}} = Depdep.Key.compute(lock, %{}, toolchain())
    end
  end

  describe "the schema prefix" do
    test "is in the key, so retiring the schema retires every object" do
      lock = [hex("ash", "3.32.3", [])]
      [{name, entry}] = lock

      assert String.starts_with?(
               Depdep.Key.object(name, entry, key(lock, "ash")),
               Depdep.Key.schema() <> "/"
             )
    end
  end

  # A git lock entry carries url, ref and opts and no child list, so its closure
  # was unknowable and it — and everything above it — was skipped.
  # `Depdep.Graph` supplies the edges Mix already resolved.
  describe "git dependencies, given Mix's resolved graph" do
    defp keys_with_graph(lock, graph) do
      {:ok, keys} = Depdep.Key.compute(Map.new(lock), %{}, toolchain(), graph)
      keys
    end

    test "are skipped without a graph, exactly as before" do
      lock = [git("forked"), hex("spark", "2.6.0", [])]
      assert {:skip, reason} = key(lock, "forked")
      assert reason =~ "git"
    end

    test "are keyed with one" do
      lock = [git("forked"), hex("spark", "2.6.0", [])]
      keys = keys_with_graph(lock, %{"forked" => ["spark"]})

      assert {:key, hash} = keys["forked"]
      assert is_binary(hash)
    end

    # The whole reason a sha-only key would be wrong, and the same argument the
    # recursion exists for: spark's macros expand into the fork's beams, so its
    # correct bytecode moves while its ref does not.
    test "bumping a hex dependency OF a git dependency changes the git dependency's key" do
      graph = %{"forked" => ["spark"]}
      before = keys_with_graph([git("forked"), hex("spark", "2.6.0", [])], graph)
      later = keys_with_graph([git("forked"), hex("spark", "2.7.0", [])], graph)

      refute before["forked"] == later["forked"]
    end

    test "an unrelated bump leaves a git dependency's key alone" do
      graph = %{"forked" => ["spark"]}

      before =
        keys_with_graph(
          [git("forked"), hex("spark", "2.6.0", []), hex("jason", "1.4.4", [])],
          graph
        )

      later =
        keys_with_graph(
          [git("forked"), hex("spark", "2.6.0", []), hex("jason", "1.4.5", [])],
          graph
        )

      assert before["forked"] == later["forked"]
    end

    # The skip used to propagate to everything above a git dependency, which is
    # what made one badly-placed fork disable caching for a whole cone.
    test "a dependent of a keyable git dependency is itself keyable" do
      lock = [hex("app", "1.0.0", ["forked"]), git("forked"), hex("spark", "2.6.0", [])]
      keys = keys_with_graph(lock, %{"forked" => ["spark"]})

      assert {:key, _} = keys["app"]
      assert {:key, _} = keys["forked"]
    end

    test "a dependent is still skipped when the git dependency cannot be keyed" do
      lock = [hex("app", "1.0.0", ["forked"]), git("forked")]
      assert {:skip, reason} = key(lock, "app")
      assert reason =~ "forked"
    end
  end
end
