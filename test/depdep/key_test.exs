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
      deps = Depdep.Deps.from_lock(lock)
      assert {:error, {:cycle, _}} = Depdep.Key.compute(deps, %{}, toolchain())
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
  # was unknowable and it — and everything above it — was skipped. Once Mix
  # has fetched it, Mix's own list of its children (`Depdep.Deps`) supplies
  # the edges.
  describe "git dependencies, given Mix's view" do
    # `mix` is `%{name => children}` for what Mix has fetched.
    defp keys_with_graph(lock, mix) do
      keys_with_mix(lock, Map.new(mix, fn {n, c} -> {n, Enum.map(c, &{&1, false})} end))
    end

    test "are skipped before Mix has fetched them, exactly as before" do
      lock = [git("forked"), hex("spark", "2.6.0", [])]
      assert {:skip, reason} = key(lock, "forked")
      assert reason =~ "git"
    end

    test "are keyed once Mix lists their children" do
      lock = [git("forked"), hex("spark", "2.6.0", [])]
      keys = keys_with_graph(lock, %{"forked" => ["spark"]})

      assert {:key, hash} = keys["forked"]
      assert is_binary(hash)
    end

    # #68/#70: a fetched leaf has children `[]` — known and empty — and is
    # keyed; one Mix has not fetched is unknown, and skipped with the reason.
    test "a leaf git dependency is keyed once fetched, skipped until then" do
      lock = [git("forked"), hex("spark", "2.6.0", [])]

      assert {:key, _} = keys_with_graph(lock, %{"forked" => []})["forked"]
      assert {:skip, reason} = keys_with_graph(lock, %{})["forked"]
      assert reason =~ "git"
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

  # v3: the declaration's build options are Mix's, and they change the bytecode
  # the same source produces — none was in the key before (#89).
  describe "the build options a declaration carries" do
    defp keyed(lock, name, opts) do
      view = %{complete?: true, deps: %{name => dep_info([], opts)}}
      keys_with_mix(lock, view)[name]
    end

    test "env: changes the key; the default is :prod, which is also what an unlisted dependency has" do
      lock = [hex("jason", "1.4.4", [])]
      assert keyed(lock, "jason", []) == key(lock, "jason") |> then(&{:key, &1})
      refute keyed(lock, "jason", env: :dev) == keyed(lock, "jason", [])
    end

    test "compile: and system_env: change the key" do
      lock = [hex("jason", "1.4.4", [])]
      plain = keyed(lock, "jason", [])
      refute keyed(lock, "jason", compile: "make") == plain
      refute keyed(lock, "jason", system_env: [{"CC", "clang"}]) == plain
    end

    test "a transitive hex dependency keys the same before and after Mix has loaded it" do
      lock = [hex("app", "1.0.0", ["jason"]), hex("jason", "1.4.4", [])]
      before = keys(lock)["jason"]

      view = %{
        complete?: true,
        deps: %{"app" => dep_info([{"jason", false}]), "jason" => dep_info([])}
      }

      assert keys_with_mix(lock, view)["jason"] == before
    end
  end

  # v3 (#89, #95): a NIF's bytes depend on the architecture and ERTS they load
  # into, and on the OS and C compiler that built them. Every NIF object in the
  # store was x86-64 bytes with nothing in its key to say so.
  describe "the toolchain fingerprint" do
    defp with_base(part), do: %{toolchain() | base: [part | toolchain().base]}
    defp with_native(part), do: %{toolchain() | native: [part | toolchain().native]}

    defp key_under(lock, name, toolchain) do
      {:ok, keys} = Depdep.Key.compute(Depdep.Deps.from_lock(Map.new(lock)), %{}, toolchain)
      keys[name]
    end

    test "the host's toolchain names arch, ERTS and the compiler environment" do
      %{base: base, native: native} = Depdep.Key.toolchain(:test)

      for prefix <-
            ~w(elixir= otp= erts= arch= env=test erl_compiler_options= elixir_erl_options= mix_target=) do
        assert Enum.any?(base, &String.starts_with?(&1, prefix)), "base lacks #{prefix}"
      end

      for prefix <- ~w(os= cc=), do: assert(Enum.any?(native, &String.starts_with?(&1, prefix)))
    end

    test "a change in the base toolchain changes every key" do
      lock = [hex("jason", "1.4.4", [])]

      refute key_under(lock, "jason", with_base("arch=aarch64-apple-darwin")) ==
               key_under(lock, "jason", toolchain())
    end

    test "the native fingerprint reaches a dependency with a native build, and only that one" do
      lock = [
        hex("bcrypt_elixir", "3.1.0", ["elixir_make"]),
        hex("elixir_make", "0.8.4", []),
        hex("jason", "1.4.4", [])
      ]

      moved = with_native("cc=clang 17")

      refute key_under(lock, "bcrypt_elixir", moved) ==
               key_under(lock, "bcrypt_elixir", toolchain())

      assert key_under(lock, "jason", moved) == key_under(lock, "jason", toolchain())
    end

    test "a dependent of a native dependency moves with it, through the recursion" do
      lock = [
        hex("app", "1.0.0", ["bcrypt_elixir"]),
        hex("bcrypt_elixir", "3.1.0", ["elixir_make"]),
        hex("elixir_make", "0.8.4", [])
      ]

      refute key_under(lock, "app", with_native("os=debian-trixie")) ==
               key_under(lock, "app", toolchain())
    end

    test "native?/1 reads the lock entry: a native build tool among the children, or make" do
      deps =
        Depdep.Deps.from_lock(
          Map.new([
            hex("bcrypt_elixir", "3.1.0", ["elixir_make"]),
            hex("explorer", "0.10.0", ["rustler_precompiled", {"rustler", true}]),
            hex("ghostty", "0.1.0", ["zigler_precompiled"]),
            hex("jason", "1.4.4", []),
            git("forked")
          ])
        )

      assert Depdep.Key.native?(deps["bcrypt_elixir"])
      assert Depdep.Key.native?(deps["explorer"])
      assert Depdep.Key.native?(deps["ghostty"])
      refute Depdep.Key.native?(deps["jason"])
      refute Depdep.Key.native?(deps["forked"]), "unknown children are not evidence either way"

      {name, {:hex, app, v, i, _tools, d, r, o}} = hex("ranch", "2.1.0", [])
      make = Depdep.Deps.from_lock(%{name => {:hex, app, v, i, [:make, :rebar3], d, r, o}})
      assert Depdep.Key.native?(make["ranch"])
    end
  end

  describe "the schema" do
    test "is v3" do
      assert Depdep.Key.object("ash", elem(hex("ash", "3.32.3", []), 1), "h") =~ ~r"^v3/"
    end
  end
end
