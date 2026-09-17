defmodule Depdep.CompileTest do
  use ExUnit.Case, async: true

  alias Depdep.{Compile, Unit}

  describe "saved_us/2 — a conservative lower bound" do
    test "the compile not done, less what the transfer cost" do
      assert Compile.saved_us(2_500_000, 400_000) == 2_100_000
    end

    test "never below zero: a transfer slower than the compile saved nothing, not less" do
      assert Compile.saved_us(100_000, 400_000) == 0
    end

    test "nothing known is nothing reported, not zero" do
      assert Compile.saved_us(nil, 400_000) == nil
    end

    test "a present unit saved the whole compile" do
      assert Compile.saved_us(2_500_000, 0) == 2_500_000
    end
  end

  describe "the note beside the build" do
    setup do
      dir = Path.join(System.tmp_dir!(), "depdep-note-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      unit = %Unit{
        group: "app",
        name: "jason",
        resolution: {:key, "abc"},
        context: %{project_dir: dir, name: "jason", build_path: "_build/test"}
      }

      %{dir: dir, unit: unit}
    end

    test "round-trips, beside the key note", %{dir: dir, unit: unit} do
      assert Compile.read(unit) == :none
      assert Compile.record(unit, 2_500_000) == :ok
      assert Compile.read(unit) == {:ok, 2_500_000}

      assert Compile.note_path(unit) ==
               Path.join([dir, "_build/test", ".depdep", "jason.compile"])
    end

    test "a note that is not a number is :none, never a guess", %{unit: unit} do
      File.mkdir_p!(Path.dirname(Compile.note_path(unit)))
      File.write!(Compile.note_path(unit), "soon")
      assert Compile.read(unit) == :none
    end
  end
end
