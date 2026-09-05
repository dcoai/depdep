defmodule Depdep.LockTest do
  @moduledoc """
  The lockfile adapter.

  `Depdep.KeyTest` builds its locks as literals with string keys, so it exercises
  the key algebra and NOT this adapter. That gap shipped a real defect:
  `mix.lock` writes `"ash":`, which parses to an ATOM key, so every
  optional-dependency lookup missed and every build of a package with optional
  dependencies keyed identically — the exact wrong-restore the recursion exists
  to prevent, with every key rule still green. These go through `Lock.read/1`.
  """
  use ExUnit.Case, async: true

  import Depdep.LockFixture

  test "a parsed lockfile is keyed by strings, not the atoms the file contains" do
    {:ok, lock} =
      write_and_read(
        ~s|%{\n  "ash": {:hex, :ash, "3.32.3", "aaaa", [:mix], [], "hexpm", "bbbb"},\n}\n|
      )

    assert Map.keys(lock) == ["ash"]
  end

  test "optional presence still keys apart after a round trip through the lockfile" do
    ash =
      ~s|"ash": {:hex, :ash, "3.32.3", "aaaa", [:mix], [{:plug, ">= 0.0.0", [hex: :plug, repo: "hexpm", optional: true]}], "hexpm", "bbbb"}|

    plug = ~s|"plug": {:hex, :plug, "1.16.0", "cccc", [:mix], [], "hexpm", "dddd"}|

    {:ok, without} = write_and_read("%{\n  #{ash},\n}\n")
    {:ok, with_plug} = write_and_read("%{\n  #{ash},\n  #{plug},\n}\n")

    refute key(Map.to_list(without), "ash") == key(Map.to_list(with_plug), "ash")
  end

  test "a missing lockfile is an error, not a crash" do
    assert {:error, _} = Depdep.Lock.read("/nonexistent/mix.lock")
  end

  test "a lockfile that is not a map is an error, not a crash" do
    assert {:error, _} = write_and_read(":not_a_map\n")
  end

  test "a git entry reports its children as unknown" do
    {_name, entry} = git("heroicons")
    assert Depdep.Lock.children(entry) == :unknown
  end
end
