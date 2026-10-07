defmodule Depdep.SweepTest do
  @moduledoc """
  The rules that decide what reclamation removes.

  Pure, so every rule is exercised without a store. What makes these safe to be
  aggressive about is that a wrong deletion costs a recompile rather than
  correctness — but "costs a recompile" is still a cost, and each rule below is
  the difference between reclaiming and paying it.
  """
  use ExUnit.Case, async: true

  alias Depdep.Sweep

  @now ~U[2026-09-07 12:00:00Z]

  defp object(key, days_old, size \\ 1000) do
    %{
      key: key,
      size: size,
      last_modified: DateTime.add(@now, -days_old, :day) |> DateTime.to_iso8601()
    }
  end

  defp doomed(objects, live, opts \\ []) do
    objects
    |> Sweep.plan(MapSet.new(live), Keyword.merge([now: @now], opts))
    |> Enum.map(fn {object, _reason} -> object.key end)
  end

  # #126: the third rail, which had no test at all. The other two guard against
  # the clock and against a slip of the hand; this one guards against the
  # OPERATOR being wrong — a store nobody uses and a misconfigured invocation
  # look identical from the outside, and one of them would empty the bucket.
  #
  # It had no test because it lived in `Depdep.CLI.Operator`, which talks to a
  # store, while every other rule lived here. The decision has moved here.
  describe "current roots — the rail against the operator being wrong" do
    @tag verifies: "sweep-refuses-without-roots"
    test "no roots at all is a refusal, not an empty live set" do
      objects = [object("v3/jason/1.4.4/abc.tar.gz", 90)]

      assert {:refuse, reason} = Sweep.current_roots(objects, now: @now)
      assert reason =~ "no root has been written"
      assert reason =~ "30"
    end

    test "only stale roots is a refusal too, because the live set would be empty" do
      objects = [
        object("roots/gone/main/mix.json", 400),
        object("v3/jason/1.4.4/abc.tar.gz", 90)
      ]

      assert {:refuse, _} = Sweep.current_roots(objects, now: @now)
    end

    test "one current root is enough to proceed, and only roots are returned" do
      root = object("roots/live/main/mix.json", 3)
      objects = [root, object("v3/jason/1.4.4/abc.tar.gz", 90)]

      assert {:ok, [^root]} = Sweep.current_roots(objects, now: @now)
    end

    @tag verifies: "spec/08-reclamation.md#Reclamation"
    test "the window is configurable, and applied against the given clock" do
      objects = [object("roots/live/main/mix.json", 45)]

      assert {:refuse, _} = Sweep.current_roots(objects, now: @now, window_days: 30)
      assert {:ok, [_]} = Sweep.current_roots(objects, now: @now, window_days: 60)
    end

    # spec/08-reclamation.md#prefixes: an unreadable age is treated as recent.
    # The helper this replaced in Depdep.CLI.Operator treated it as stale, which
    # would drop the root from the live set and expose everything it protects.
    # Keeping it costs disk; dropping it costs an object somebody still wanted.
    test "an unparseable timestamp counts as current, the fail-safe direction" do
      objects = [%{key: "roots/live/main/mix.json", size: 10, last_modified: "not a date"}]

      assert {:ok, [_]} = Sweep.current_roots(objects, now: @now)
    end
  end

  # These name the CURRENT schema deliberately. They were written when `v2` was current
  # and #166 retired it, which made every one of them fail — a retired schema's objects
  # are swept regardless of the live set, so "a live mix object" has to be spelled with
  # whatever `Depdep.Key.schema/0` returns today.
  describe "mix objects" do
    @tag verifies: "spec/08-reclamation.md#Reclamation"
    test "an object a current root names survives" do
      objects = [object("v3/jason/1.4.4/aaa.tar.gz", 10)]
      assert doomed(objects, ["v3/jason/1.4.4/aaa.tar.gz"]) == []
    end

    test "an object no root names goes" do
      objects = [object("v3/jason/1.4.3/old.tar.gz", 10)]
      assert doomed(objects, ["v3/jason/1.4.4/aaa.tar.gz"]) == ["v3/jason/1.4.3/old.tar.gz"]
    end

    # A consumer pushing while the listing was taken has written something no
    # root names yet. Deleting it would be a race, not a reclamation.
    test "anything inside the grace period survives even when unreachable" do
      objects = [object("v3/jason/1.4.3/fresh.tar.gz", 1)]
      assert doomed(objects, []) == []
    end

    @tag verifies: "spec/08-reclamation.md#rails"
    test "the grace period is configurable and applied against the given clock" do
      objects = [object("v3/a/1/x.tar.gz", 5)]
      assert doomed(objects, [], grace_days: 7) == []
      assert doomed(objects, [], grace_days: 2) == ["v3/a/1/x.tar.gz"]
    end
  end

  # #169, for #125. The classification both --report and --sweep ask, so the command an
  # operator reads before deleting and the delete itself cannot disagree about what a key
  # is. `Operator.group/1` used to decide this separately, with a literal `"v2"`, and the
  # v3 bump desynchronised them: the report printed 128 groups where one belonged.
  describe "rule_for/1 — the one classification" do
    @tag verifies: "spec/08-reclamation.md#prefixes"
    test "each named prefix has its rule, and mix is the fall-through" do
      assert Sweep.rule_for("apt/v1/debian-bookworm/libbsd0.deb") == :apt
      assert Sweep.rule_for("roots/consumer/main/mix.json") == :roots
      assert Sweep.rule_for("git/v1/some-repo/1700000000/mirror.tar.gz") == :git
      assert Sweep.rule_for("src/v1/some-repo/abc123/source.tar.gz") == :source
      assert Sweep.rule_for("#{Depdep.Key.schema()}/jason/1.4.4/aaa.tar.gz") == :mix
      assert Sweep.rule_for("#{hd(Depdep.Key.retired())}/jason/1.4.4/aaa.tar.gz") == :retired
    end

    # **The property that matters.** `:mix` is "not one of the named prefixes", so a schema
    # nobody has invented yet is already classified correctly — which is why the v2 -> v3
    # bump did not break reclamation, and why the next bump cannot break the report.
    test "a schema that does not exist yet is mix, without being taught about it" do
      assert Sweep.rule_for("v9/jason/1.4.4/aaa.tar.gz") == :mix
      assert Sweep.rule_for("v4000/ash/3.0.0/bbb.tar.gz") == :mix
    end

    # src/ is decided exactly as mix by the sweep (#165) and is still named separately,
    # because `src/v1` is not a schema and the report says more by keeping it.
    test "source is named although the sweep decides it exactly as mix" do
      source = object("src/v1/repo/abc/source.tar.gz", 10)
      mix = object("#{Depdep.Key.schema()}/jason/1.4.4/aaa.tar.gz", 10)

      assert doomed([source, mix], []) |> Enum.sort() == Enum.sort([source.key, mix.key])
      assert doomed([source, mix], [source.key, mix.key]) == []
    end
  end

  # #166, for #140. The property spec/03-keys.md#object-path claims — that retiring a
  # schema is a matter of writing under a new prefix rather than deleting anything — was
  # half true: writing was easy, removing was impossible, because stale roots named the
  # old prefix and marking spared it forever.
  describe "a retired schema" do
    @retired "v2/jason/1.4.4/aaa.tar.gz"

    # The whole point: the live set CANNOT change the answer. No running depdep builds a
    # v2 path, so a root naming one was written by a version nobody runs.
    @tag verifies: "retired-schema-is-swept-regardless-of-roots"
    test "is swept even when a current root names it" do
      objects = [object(@retired, 10)]

      assert doomed(objects, [@retired]) == [@retired]
    end

    test "the reason names the schema, so a report says why" do
      [{_object, reason}] =
        Sweep.plan([object(@retired, 10)], MapSet.new([@retired]), now: @now)

      assert reason =~ "v2"
      assert reason =~ "retired"
    end

    # The grace window is about a push racing a listing, which does not care which
    # schema it is.
    test "is still protected by the grace window" do
      assert doomed([object(@retired, 0)], [], grace_days: 2) == []
    end

    # The rule must not widen: a current-schema object is decided by reachability, as
    # before.
    test "does not take the current schema with it" do
      live = "v3/jason/1.4.4/aaa.tar.gz"

      assert doomed([object(live, 10)], [live]) == []
      assert doomed([object(live, 10)], []) == [live]
    end
  end

  describe "apt objects" do
    # Small, near-static, shared across every consumer, and their reachable set
    # cannot be computed without apt in the right container. Never swept.
    @tag verifies: "spec/08-reclamation.md#prefixes"
    test "are never removed, reachable or not" do
      objects = [object("apt/v1/debian-trixie/cpp_4%3a12.2.0-3_amd64.deb", 400)]
      assert doomed(objects, []) == []
    end
  end

  # #165, for #151. A new prefix needs a rule or an explicit decision; this one takes the
  # fallback deliberately, and that is verified rather than assumed.
  describe "a git dependency's source" do
    @source "src/v1/example.invalid-group-proj/1ff2282c63419e6c410a1595ee3bf42a7ec5f4cd/source.tar.gz"

    # Unlike apt, a source object's reachable set IS computable: every unit's object goes
    # into the root its consumer writes on each pull, so a source nobody wants any more
    # ages out with the consumers that stopped wanting it.
    @tag verifies: "source-objects-are-reclaimed-by-reachability"
    test "is swept when no current root names it" do
      objects = [object(@source, 90), object("roots/live/main/mix.json", 3)]

      assert doomed(objects, []) == [@source]
    end

    test "is kept when a current root names it" do
      objects = [object(@source, 90), object("roots/live/main/mix.json", 3)]

      assert doomed(objects, [@source]) == []
    end

    # The grace window applies here as everywhere: a source pushed moments ago must not be
    # swept by a listing that raced it.
    test "is protected by the grace window like any other object" do
      objects = [object(@source, 0), object("roots/live/main/mix.json", 3)]

      assert doomed(objects, [], grace_days: 2) == []
    end
  end

  describe "git mirrors" do
    # Superseded rather than unreachable: a mirror is a seed whose staleness is
    # harmless, so age is the truer rule and marking would keep every epoch any
    # consumer ever pulled.
    test "the newest epochs survive and older ones go, whatever the roots say" do
      objects = [
        object("git/v1/host-a/2026-09/mirror.tar.gz", 5),
        object("git/v1/host-a/2026-08/mirror.tar.gz", 40),
        object("git/v1/host-a/2026-07/mirror.tar.gz", 70),
        object("git/v1/host-a/2026-06/mirror.tar.gz", 100)
      ]

      # Every one is named by a current root, and the old ones still go.
      live = Enum.map(objects, & &1.key)

      assert doomed(objects, live, keep_epochs: 2) == [
               "git/v1/host-a/2026-07/mirror.tar.gz",
               "git/v1/host-a/2026-06/mirror.tar.gz"
             ]
    end

    test "a repository with fewer epochs than the keep count is untouched" do
      objects = [object("git/v1/host-b/2026-09/mirror.tar.gz", 60)]
      assert doomed(objects, [], keep_epochs: 2) == []
    end

    test "repositories are counted separately" do
      objects = [
        object("git/v1/host-a/2026-09/mirror.tar.gz", 5),
        object("git/v1/host-a/2026-08/mirror.tar.gz", 40),
        object("git/v1/host-b/2026-09/mirror.tar.gz", 5)
      ]

      assert doomed(objects, [], keep_epochs: 1) == ["git/v1/host-a/2026-08/mirror.tar.gz"]
    end
  end

  describe "roots" do
    # They overwrite per consumer, ref and provider, so they accumulate only
    # when a branch dies — but the thing that solves unbounded growth must not
    # grow unboundedly.
    test "a stale root goes and a current one stays" do
      objects = [
        object("roots/dco-tek-bizex/main/mix", 2),
        object("roots/dco-tek-bizex/dead-branch/mix", 200)
      ]

      assert doomed(objects, [], window_days: 30) == ["roots/dco-tek-bizex/dead-branch/mix"]
    end
  end

  describe "an unparseable timestamp" do
    # Unknown age is treated as new: keeping costs disk, deleting wrongly costs
    # a recompile.
    test "is treated as recent, not as ancient" do
      objects = [%{key: "v3/a/1/x.tar.gz", size: 1, last_modified: "not a date"}]
      assert doomed(objects, []) == []
    end
  end

  describe "protected/2" do
    @tag verifies: "spec/08-reclamation.md#prefixes"
    test "counts what the grace period is holding" do
      objects = [object("v3/a/1/x.tar.gz", 1), object("v3/a/1/y.tar.gz", 30)]
      assert Sweep.protected(objects, now: @now, grace_days: 2) == 1
    end
  end
end
