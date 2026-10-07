defmodule Depdep.Provider.Mix.SourceTest do
  @moduledoc """
  A git dependency's source key: the repository and the locked commit, and nothing else.

  Pure — no store, no network, no checkout. That is the point of the key being this
  simple: a source's bytes are determined by its commit, so there is nothing here that
  could depend on the host (#163, for #151).
  """
  use ExUnit.Case, async: true

  alias Depdep.Provider.Mix.Source

  @commit "1ff2282c63419e6c410a1595ee3bf42a7ec5f4cd"

  defp git(url, rev, opts \\ []), do: {:git, url, rev, opts}

  describe "the two spellings of one repository" do
    # #123's lesson applied before the fact: keying on the URL as written would store
    # one copy of a commit per way of writing its address. extla's objects already
    # exist in production under both spellings for the compiled key's unrelated reasons.
    @tag verifies: "source-key-shares-one-object-per-commit"
    test "share one object" do
      ssh = git("git@gitlab.example.com:group/proj.git", @commit)
      https = git("https://gitlab.example.com/group/proj.git", @commit)

      assert Source.object(ssh) == Source.object(https)
    end

    test "and a trailing .git is not part of the identity either" do
      with_suffix = git("https://gitlab.example.com/group/proj.git", @commit)
      without = git("https://gitlab.example.com/group/proj", @commit)

      assert Source.object(with_suffix) == Source.object(without)
    end
  end

  describe "the commit is the whole identity" do
    test "a different commit is a different object" do
      refute Source.object(git("https://h/a.git", @commit)) ==
               Source.object(git("https://h/a.git", String.replace(@commit, "1ff", "2aa")))
    end

    # The tag is what a human pinned; the sha is what was fetched. Two entries at one
    # commit must agree even when one names a tag and the other does not, or a consumer
    # that pins `tag:` and one that pins `ref:` would never share.
    test "a tag-pinned entry and a ref-pinned entry at one commit agree" do
      tagged = git("https://h/a.git", @commit, tag: "v2.1.1")
      reffed = git("https://h/a.git", @commit, ref: @commit)

      assert Source.object(tagged) == Source.object(reffed)
    end

    test "the commit is the path segment, not a digest of it" do
      {:ok, path} = Source.object(git("https://h/a.git", @commit))

      assert path =~ @commit, "the commit IS the content address; hashing it hides it"
    end
  end

  describe "the object path" do
    # One segment for the repository, as `slug/1` produces — it doubles as a directory
    # name for a mirror, so it cannot carry slashes. That also keeps the object path the
    # same shape as every other prefix here: one segment for the thing, one for its
    # version, then the file.
    test "is readable: prefix, repository, commit" do
      {:ok, path} = Source.object(git("https://gitlab.example.com/group/proj.git", @commit))

      assert path ==
               "#{Source.prefix()}/gitlab.example.com-group-proj/#{@commit}/source.tar.gz"
    end

    test "carries its own prefix, so the scheme can be retired in one sweep" do
      {:ok, path} = Source.object(git("https://h/a.git", @commit))
      assert String.starts_with?(path, Source.prefix() <> "/")
    end
  end

  describe "a non-git entry" do
    # A hex dependency's source is a tarball Mix fetches by checksum. Answering :not_git
    # rather than inventing a path keeps the caller honest about which entries this is for.
    test "has no source object and no commit" do
      hex = {:hex, :jason, "1.4.4", "inner", [:mix], [], "hexpm", "outer"}

      assert Source.commit(hex) == :not_git
      assert Source.object(hex) == :not_git
    end
  end
end
