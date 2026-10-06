defmodule Depdep.Provider.GitTest do
  @moduledoc """
  Real git throughout, but no network: the "remote" is a local repository this
  test creates.

  Included by default rather than tagged out, because git is not optional for
  this project — depdep is bootstrapped with
  `Mix.install([{:depdep, git: ...}])`, so any machine that can run it has git.
  """
  use ExUnit.Case, async: true

  alias Depdep.Provider.Git

  defp git!(args, opts \\ []) do
    {output, 0} = System.cmd("git", args, [stderr_to_stdout: true] ++ opts)
    output
  end

  defp source_repo do
    path = Path.join(System.tmp_dir!(), "depdep-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    git!(["init", "--initial-branch", "main", "."], cd: path)
    git!(["config", "user.email", "test@example.invalid"], cd: path)
    git!(["config", "user.name", "Depdep Test"], cd: path)
    File.write!(Path.join(path, "README.md"), "the source of truth\n")
    git!(["add", "."], cd: path)
    git!(["commit", "-m", "initial"], cd: path)
    path
  end

  describe "slug/1" do
    # The same repository reached two ways is one repository. Storing it twice
    # would waste the space AND misreport what is cached.
    # `slug/1` is one of the three functions `#git` names, and nothing verified the
    # section before #154. This covers the claim that the slug names the REPOSITORY
    # rather than the URL that reached it.
    @tag verifies: "spec/05-units-and-providers.md#git"
    test "https and ssh forms of one repository agree" do
      assert Git.slug("https://gitlab.example.com/group/proj.git") ==
               Git.slug("git@gitlab.example.com:group/proj.git")
    end

    test "is readable rather than hashed, so the store can be browsed" do
      assert Git.slug("https://gitlab.example.com/group/proj.git") ==
               "gitlab.example.com-group-proj"
    end

    test "distinguishes different repositories on the same host" do
      refute Git.slug("https://h/a.git") == Git.slug("https://h/b.git")
    end
  end

  describe "epoch/0" do
    test "is the current month" do
      assert Git.epoch() == Calendar.strftime(Date.utc_today(), "%Y-%m")
      assert Git.epoch() =~ ~r/^\d{4}-\d{2}$/
    end
  end

  describe "enumerate/1" do
    test "no repositories named is no work, and no complaint" do
      assert Git.enumerate(direction: :pull) == {:ok, [], []}
    end

    # The section's normative claim about the key: repository plus a monthly epoch
    # rather than a commit, which is what a stale mirror being harmless buys. Nothing
    # verified `#git` before this (#154) — the section's four `implements` relations
    # had no test behind them, so a rewording of it could not be reviewed.
    @tag verifies: "spec/05-units-and-providers.md#git"
    test "one unit per repository, keyed on the epoch" do
      assert {:ok, [unit], []} =
               Git.enumerate(direction: :pull, repo: "https://h/a.git", git_mirror_dir: "/tmp/m")

      assert unit.name == "h-a"
      assert unit.resolution == {:key, Git.epoch()}
      assert unit.object == "git/v1/h-a/#{Git.epoch()}/mirror.tar.gz"
      assert unit.group == nil
    end
  end

  describe "present?/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-mir-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, [unit], []} =
        Git.enumerate(direction: :pull, repo: "https://h/a.git", git_mirror_dir: dir)

      %{dir: dir, unit: unit}
    end

    test "on a pull, whether the mirror is already on disk", %{unit: unit} do
      refute Git.present?(unit)

      File.mkdir_p!(Git.mirror_path(unit))
      refute Git.present?(unit), "a directory without a HEAD is not a mirror"

      File.write!(Path.join(Git.mirror_path(unit), "HEAD"), "ref: refs/heads/main\n")
      assert Git.present?(unit)
    end

    # A mirror is always obtainable from the repository itself, so a push can
    # always offer one. What stops that being expensive is the store: `collect/2`
    # runs only on a HEAD miss, so the clone happens once per repository per
    # month rather than once per pipeline.
    test "on a push, always — the mirror can be produced", %{unit: unit} do
      assert Git.present?(%{unit | context: %{unit.context | direction: :push}})
    end
  end

  describe "collect then restore" do
    setup do
      source = source_repo()
      collect_dir = Path.join(System.tmp_dir!(), "depdep-c-#{System.unique_integer([:positive])}")
      restore_dir = Path.join(System.tmp_dir!(), "depdep-r-#{System.unique_integer([:positive])}")
      tmp = Path.join(System.tmp_dir!(), "depdep-t-#{System.unique_integer([:positive])}.tar.gz")

      on_exit(fn ->
        Enum.each([source, collect_dir, restore_dir], &File.rm_rf!/1)
        File.rm(tmp)
      end)

      %{source: source, collect_dir: collect_dir, restore_dir: restore_dir, tmp: tmp}
    end

    defp unit_for(source, dir, direction) do
      {:ok, [unit], []} = Git.enumerate(direction: direction, repo: source, git_mirror_dir: dir)
      unit
    end

    test "collect clones a mirror when there is none yet", ctx do
      unit = unit_for(ctx.source, ctx.collect_dir, :push)

      assert Git.collect(unit, ctx.tmp) == :ok
      assert File.regular?(ctx.tmp)
      assert File.regular?(Path.join(Git.mirror_path(unit), "HEAD"))
    end

    # `mirror_path/1` is the third function `#git` names — "where a mirror lands" —
    # and this is the test that asserts something really lands there and is a usable
    # repository rather than a directory of files (#154).
    @tag verifies: "spec/05-units-and-providers.md#git"
    test "a restored mirror is a sound repository, not just some files", ctx do
      assert Git.collect(unit_for(ctx.source, ctx.collect_dir, :push), ctx.tmp) == :ok

      restored = unit_for(ctx.source, ctx.restore_dir, :pull)
      refute Git.present?(restored)
      assert Git.restore(restored, ctx.tmp) == :ok
      assert Git.present?(restored)

      # The claim a tar of a bare repository has to earn: git itself accepts it.
      assert {_, 0} = System.cmd("git", ["--git-dir", Git.mirror_path(restored), "fsck"])
    end

    # #98: a bare mirror's objects are read-only too, so a monthly re-pull over
    # the mirror that is already there has to replace it, not extract over it.
    test "a restore over an existing mirror replaces it", ctx do
      assert Git.collect(unit_for(ctx.source, ctx.collect_dir, :push), ctx.tmp) == :ok
      restored = unit_for(ctx.source, ctx.restore_dir, :pull)
      assert Git.restore(restored, ctx.tmp) == :ok
      assert Git.present?(restored)

      assert Git.restore(restored, ctx.tmp) == :ok
      assert {_, 0} = System.cmd("git", ["--git-dir", Git.mirror_path(restored), "fsck"])
    end

    # The point of the whole provider: a clone served from the mirror rather
    # than from the remote, and identical to one that was not.
    test "a restored mirror serves a --reference clone", ctx do
      assert Git.collect(unit_for(ctx.source, ctx.collect_dir, :push), ctx.tmp) == :ok
      restored = unit_for(ctx.source, ctx.restore_dir, :pull)
      assert Git.restore(restored, ctx.tmp) == :ok

      checkout = Path.join(System.tmp_dir!(), "depdep-co-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(checkout) end)

      # An explicit cwd: the VM's is shared state that another test can move.
      git!(
        [
          "clone",
          "--reference",
          Git.mirror_path(restored),
          "--dissociate",
          ctx.source,
          checkout
        ],
        cd: System.tmp_dir!()
      )

      assert File.read!(Path.join(checkout, "README.md")) == "the source of truth\n"
    end

    test "collect updates an existing mirror rather than recloning", ctx do
      unit = unit_for(ctx.source, ctx.collect_dir, :push)
      assert Git.collect(unit, ctx.tmp) == :ok

      File.write!(Path.join(ctx.source, "later.md"), "a second commit\n")
      git!(["add", "."], cd: ctx.source)
      git!(["commit", "-m", "later"], cd: ctx.source)

      assert Git.collect(unit, ctx.tmp) == :ok

      log = git!(["--git-dir", Git.mirror_path(unit), "log", "--oneline"])
      assert log =~ "later"
    end

    test "an unreachable repository is an error, not a crash", ctx do
      unit = unit_for("/definitely/not/a/repo", ctx.collect_dir, :push)

      assert {:error, reason} = Git.collect(unit, ctx.tmp)
      assert reason =~ "git clone"
    end
  end
end
