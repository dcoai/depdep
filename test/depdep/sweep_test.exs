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

  describe "mix objects" do
    test "an object a current root names survives" do
      objects = [object("v2/jason/1.4.4/aaa.tar.gz", 10)]
      assert doomed(objects, ["v2/jason/1.4.4/aaa.tar.gz"]) == []
    end

    test "an object no root names goes" do
      objects = [object("v2/jason/1.4.3/old.tar.gz", 10)]
      assert doomed(objects, ["v2/jason/1.4.4/aaa.tar.gz"]) == ["v2/jason/1.4.3/old.tar.gz"]
    end

    # A consumer pushing while the listing was taken has written something no
    # root names yet. Deleting it would be a race, not a reclamation.
    test "anything inside the grace period survives even when unreachable" do
      objects = [object("v2/jason/1.4.3/fresh.tar.gz", 1)]
      assert doomed(objects, []) == []
    end

    test "the grace period is configurable and applied against the given clock" do
      objects = [object("v2/a/1/x.tar.gz", 5)]
      assert doomed(objects, [], grace_days: 7) == []
      assert doomed(objects, [], grace_days: 2) == ["v2/a/1/x.tar.gz"]
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
      objects = [%{key: "v2/a/1/x.tar.gz", size: 1, last_modified: "not a date"}]
      assert doomed(objects, []) == []
    end
  end

  describe "protected/2" do
    test "counts what the grace period is holding" do
      objects = [object("v2/a/1/x.tar.gz", 1), object("v2/a/1/y.tar.gz", 30)]
      assert Sweep.protected(objects, now: @now, grace_days: 2) == 1
    end
  end
end
