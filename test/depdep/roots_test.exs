defmodule Depdep.RootsTest do
  @moduledoc """
  What a consumer records about what it still needs.

  The point of a root is that reclamation can be precise without the operator
  gathering every checkout — so what matters here is that a root survives the
  round trip, that two consumers cannot collide, and that a malformed one is an
  error rather than a silent empty answer.
  """
  use ExUnit.Case, async: true

  alias Depdep.Roots

  describe "path/3" do
    # A consumer that runs `--pull --provider mix` and `--pull --provider apt`
    # separately must not have the second overwrite the first, or half its live
    # set disappears and reclamation deletes objects it is still using.
    test "keys by consumer, ref AND provider" do
      refute Roots.path("g/p", "main", "mix") == Roots.path("g/p", "main", "apt")
      refute Roots.path("g/p", "main", "mix") == Roots.path("g/p", "release", "mix")
      refute Roots.path("g/p", "main", "mix") == Roots.path("g/other", "main", "mix")
    end

    test "is readable, like every other object path here" do
      assert Roots.path("dco-tek/bizex", "main", "mix") == "roots/dco-tek-bizex/main/mix"
    end

    test "keeps a path inside the roots prefix" do
      assert String.starts_with?(Roots.path("a", "b", "c"), Roots.prefix())
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trip" do
      paths = ["v2/jason/1.4.4/abc.tar.gz", "apt/v1/debian-trixie/git_1_amd64.deb"]
      assert {:ok, decoded} = Roots.decode(Roots.encode(paths))
      assert Enum.sort(decoded) == Enum.sort(paths)
    end

    test "an empty live set encodes and decodes as empty" do
      assert {:ok, []} = Roots.decode(Roots.encode([]))
    end

    test "paths are sorted, so an unchanged live set writes an unchanged root" do
      assert Roots.encode(["b", "a"]) == Roots.encode(["a", "b"])
    end

    # One malformed root must not make a whole store look unreachable — the
    # caller reports and skips, which it can only do if this says so.
    test "an unrecognised format is an error, not an empty list" do
      assert {:error, reason} = Roots.decode("some other file entirely\n")
      assert reason =~ "unrecognised"
    end

    test "an empty file is an error" do
      assert {:error, _} = Roots.decode("")
    end
  end

  describe "identity/2" do
    setup do
      saved = {System.get_env("CI_PROJECT_PATH"), System.get_env("CI_COMMIT_REF_SLUG")}

      on_exit(fn ->
        {project, ref} = saved

        if project,
          do: System.put_env("CI_PROJECT_PATH", project),
          else: System.delete_env("CI_PROJECT_PATH")

        if ref,
          do: System.put_env("CI_COMMIT_REF_SLUG", ref),
          else: System.delete_env("CI_COMMIT_REF_SLUG")
      end)

      System.delete_env("CI_PROJECT_PATH")
      System.delete_env("CI_COMMIT_REF_SLUG")
      :ok
    end

    test "CI names itself" do
      System.put_env("CI_PROJECT_PATH", "dco-tek/bizex")
      System.put_env("CI_COMMIT_REF_SLUG", "main")

      assert Roots.identity([], "/anywhere") == {"dco-tek/bizex", "main"}
    end

    # Two developers sharing one root would each halve the other's live set,
    # and reclamation would then delete objects still in use.
    test "outside CI, the checkout is qualified by host" do
      {consumer, ref} = Roots.identity([], "/home/someone/bizex")

      assert consumer =~ "bizex"
      assert consumer =~ "local-"
      assert ref == "unknown"
    end

    test "explicit flags win over the environment" do
      System.put_env("CI_PROJECT_PATH", "ignored")
      assert Roots.identity([consumer: "chosen", ref: "v2"], "/x") == {"chosen", "v2"}
    end
  end
end
