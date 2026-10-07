defmodule Depdep.CompileTest do
  use ExUnit.Case, async: true

  alias Depdep.{Compile, Unit}

  # What --compile-deps names to Mix: the misses, and nothing restored. Every
  # unit here is one Mix's own list says this env builds (#89), so there is
  # no verdict to hold on any more.
  describe "select/2 — the misses" do
    defp unit(name) do
      %Unit{
        group: "app",
        name: name,
        resolution: {:key, "abc"},
        object: nil,
        detail: "-",
        context: %{project_dir: "/app", name: name, env: :test}
      }
    end

    @tag verifies: "spec/06-the-run.md#compile-deps"
    test "misses by label; a hit is not mentioned" do
      units = [unit("jason"), unit("earmark_parser"), unit("spark")]

      assert [%Unit{name: "jason"}, %Unit{name: "earmark_parser"}] =
               Compile.select(units, ["app/jason", "app/earmark_parser"])
    end

    # The no-store path has no pull to say what is missing; it asks a predicate.
    test "given a predicate, the same selection" do
      units = [unit("jason"), unit("spark")]
      assert [%Unit{name: "jason"}] = Compile.select(units, &(&1.name != "spark"))
    end

    test "nothing missing, nothing compiled" do
      assert Compile.select([unit("jason")], []) == []
    end
  end

  # uficap's first apt push (#85): `upload/4` asks every unit for its compile
  # time, and a `.deb` has no build to have one.
  describe "read/1 on a unit that is not a mix unit" do
    test "an apt unit has no compile time, and asking is not a crash" do
      unit = %Unit{
        group: nil,
        name: "libbsd0_0.11.7-2_amd64.deb",
        detail: "-",
        resolution: {:key, "libbsd0_0.11.7-2_amd64.deb"},
        object: "apt/v1/debian-bookworm/libbsd0_0.11.7-2_amd64.deb",
        context: %{
          filename: "libbsd0_0.11.7-2_amd64.deb",
          checksum: nil,
          dir: "/var/cache/apt/archives"
        }
      }

      assert Compile.read(unit) == :none
      assert Compile.saved_us(nil, 0) == nil
    end

    test "a git mirror unit likewise" do
      unit = %Unit{
        group: nil,
        name: "mirror",
        detail: "-",
        resolution: {:key, "x"},
        object: nil,
        context: %{repo: "x"}
      }

      assert Compile.read(unit) == :none
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
