defmodule Depdep.Provider.Mix.SourceUnitTest do
  @moduledoc """
  Source units through the provider's five callbacks (#164, for #151).

  The fail-safe case is the reason this file exists. A restored checkout that is NOT at
  the locked commit must be reported as a miss, so `mix deps.get` clones it and the run
  says so. Accepting it silently would leave Mix to re-clone anyway — the exact cost the
  work item exists to remove — with nothing in the log saying the restore was useless.
  """
  use ExUnit.Case, async: false

  alias Depdep.Provider
  alias Depdep.Provider.Mix.Source

  setup do
    base = Path.join(System.tmp_dir!(), "src-unit-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "app")
    checkout = Path.join([dir, "deps", "forked"])
    File.mkdir_p!(checkout)
    on_exit(fn -> File.rm_rf!(base) end)

    git = fn args ->
      {_, 0} = System.cmd("git", ["-C", checkout | args], stderr_to_stdout: true)
    end

    File.write!(Path.join(checkout, "mix.exs"), "defmodule Forked.MixProject do\nend\n")
    git.(["init", "--quiet"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "one"])
    git.(["remote", "add", "origin", "ssh://git@elsewhere.invalid/forked.git"])
    {sha, 0} = System.cmd("git", ["-C", checkout, "rev-parse", "HEAD"])
    sha = String.trim(sha)

    lock = """
    %{"forked": {:git, "https://example.invalid/forked.git", "#{sha}", []}}
    """

    File.write!(Path.join(dir, "mix.lock"), lock)
    {:ok, units, _} = Provider.Mix.enumerate(root: base, env: :test, project: "app")
    unit = Enum.find(units, &(&1.context[:kind] == :source))

    %{base: base, dir: dir, checkout: checkout, sha: sha, unit: unit}
  end

  test "a source unit is keyed on the locked commit and named apart from the build", ctx do
    assert ctx.unit.name == "forked (source)"
    assert ctx.unit.resolution == {:key, ctx.sha}

    assert ctx.unit.object ==
             elem(Source.object({:git, "https://example.invalid/forked.git", ctx.sha, []}), 1)
  end

  test "present? is true when the checkout is at the locked commit", ctx do
    assert Provider.Mix.present?(ctx.unit)
  end

  # THE FAIL-SAFE. A checkout at another commit is not the thing the lock asked for, so
  # it must not be reported as present — the run then treats it as a miss, deps.get
  # fetches, and the log says so.
  @tag verifies: "source-unit-is-a-miss-unless-at-the-locked-commit"
  test "present? is false when the checkout is at another commit", ctx do
    git = fn args ->
      {_, 0} = System.cmd("git", ["-C", ctx.checkout | args], stderr_to_stdout: true)
    end

    File.write!(Path.join(ctx.checkout, "more.ex"), "defmodule More do\nend\n")
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "two"])

    refute Provider.Mix.present?(ctx.unit),
           "a checkout at another commit was accepted as the locked one, so Mix would " <>
             "re-clone it with nothing saying the restore was useless"
  end

  test "present? is false when there is no repository at all", ctx do
    File.rm_rf!(Path.join(ctx.checkout, ".git"))
    refute Provider.Mix.present?(ctx.unit)
  end

  test "collect then restore reproduces the checkout and adopts this consumer's origin", ctx do
    tmp = Path.join(System.tmp_dir!(), "src-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(tmp) end)

    assert Provider.Mix.collect(ctx.unit, tmp) == :ok

    File.rm_rf!(ctx.checkout)
    refute Provider.Mix.present?(ctx.unit)

    assert Provider.Mix.restore(ctx.unit, tmp) == :ok
    assert Provider.Mix.present?(ctx.unit), "the restored checkout is at the locked commit"

    # #144's mechanism: the object carries the PUSHER's origin and Mix compares it as a
    # string, so the restore points it at this consumer's lock URL.
    {origin, 0} = System.cmd("git", ["-C", ctx.checkout, "config", "remote.origin.url"])
    assert String.trim(origin) == "https://example.invalid/forked.git"
  end

  # record/1 writes nothing: present? asks git, so there is no note to drift.
  test "record is a no-op", ctx do
    assert Provider.Mix.record(ctx.unit) == :ok
  end
end
