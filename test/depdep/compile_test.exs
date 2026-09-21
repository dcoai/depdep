defmodule Depdep.CompileTest do
  use ExUnit.Case, async: true

  alias Depdep.{Compile, Unit}

  # extc's failure (#81): a miss the env walk could only call ambiguous was
  # named to `mix deps.compile`, which refused it for the env and ended the run.
  describe "select/2 — only misses this env is known to build" do
    defp unit(name, verdict) do
      %Unit{
        group: "app",
        name: name,
        resolution: {:key, "abc"},
        object: nil,
        detail: "-",
        context: %{project_dir: "/app", name: name, env: :test, env_verdict: verdict}
      }
    end

    test "an active miss is compiled, an ambiguous one is held, a hit is not mentioned" do
      units = [unit("jason", :active), unit("earmark_parser", :ambiguous), unit("spark", :active)]

      assert {[%Unit{name: "jason"}], [%Unit{name: "earmark_parser"}]} =
               Compile.select(units, ["app/jason", "app/earmark_parser"])
    end

    # The no-store path has no pull to say what is missing; it asks a predicate.
    test "given a predicate, the same split: absent active compiled, absent ambiguous held" do
      units = [unit("jason", :active), unit("earmark_parser", :ambiguous), unit("spark", :active)]
      absent? = &(&1.name != "spark")

      assert {[%Unit{name: "jason"}], [%Unit{name: "earmark_parser"}]} =
               Compile.select(units, absent?)
    end

    test "the held line names the unit and the env, and is the same on both paths" do
      assert Compile.held_warning(unit("earmark_parser", :ambiguous), :test) ==
               "app/earmark_parser: not compiled — may be outside MIX_ENV=test, " <>
                 "the dependency graph was not available"
    end

    test "nothing missing, nothing compiled, nothing held" do
      assert Compile.select([unit("jason", :active)], []) == {[], []}
    end
  end

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
