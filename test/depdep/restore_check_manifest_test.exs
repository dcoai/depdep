defmodule Depdep.RestoreCheck.ManifestTest do
  @moduledoc """
  The comparison `--explain-rebuilt` prints (#135).

  Pure, so every verdict is exercised without a filesystem — the half with the
  logic is on the testable side of `spec/02-architecture.md#purity`, which #126 is
  the cautionary example for.
  """
  use ExUnit.Case, async: true

  alias Depdep.RestoreCheck.Manifest

  @vsn {"1.20.4", ~c"29"}
  @lock {:hex, :telemetry, "1.3.0", "inner", [:mix], [], "hexpm", "outer"}
  @expected {@vsn, Hex.SCM, @lock}

  defp fields(stored), do: Manifest.compare(stored, @expected) |> Map.new()

  describe "compare/2 — in the order Mix compares them" do
    @tag verifies: "manifest-comparison-names-the-element"
    test "everything agreeing is three :same verdicts and nothing differing" do
      verdicts = Manifest.compare(@expected, @expected)

      assert Keyword.keys(verdicts) == [:elixir_otp, :scm, :lock]
      assert Enum.all?(verdicts, fn {_f, v} -> v == :same end)
      refute Manifest.differs?(verdicts)
    end

    test "a different Elixir/OTP pair is named, with both values" do
      assert %{elixir_otp: {:differs, detail}, scm: :same, lock: :same} =
               fields({{"1.19.0", ~c"28"}, Hex.SCM, @lock})

      assert detail.stored == {"1.19.0", ~c"28"}
      assert detail.expected == @vsn
    end

    test "a different SCM is named" do
      assert %{scm: {:differs, detail}, elixir_otp: :same, lock: :same} =
               fields({@vsn, Mix.SCM.Git, @lock})

      assert detail.stored == Mix.SCM.Git
    end
  end

  describe "the lock element index — the whole point of the feature" do
    test "the outer checksum is element 7" do
      assert %{lock: {:differs, %{element: 7}}} =
               fields({@vsn, Hex.SCM, put_elem(@lock, 7, "other")})
    end

    test "the repo is element 6" do
      assert %{lock: {:differs, %{element: 6}}} =
               fields({@vsn, Hex.SCM, put_elem(@lock, 6, "mirror")})
    end

    test "the dependency list is element 5" do
      deps = [{:x, ">= 0.0.0", [hex: :x, repo: "hexpm", optional: true]}]

      assert %{lock: {:differs, %{element: 5}}} =
               fields({@vsn, Hex.SCM, put_elem(@lock, 5, deps)})
    end

    test "the FIRST differing element is the one named, not the last" do
      changed = @lock |> put_elem(3, "other-inner") |> put_elem(7, "other-outer")
      assert %{lock: {:differs, %{element: 3}}} = fields({@vsn, Hex.SCM, changed})
    end

    test "a git entry against a hex entry is :shape, since no element is comparable" do
      git = {:git, "https://example.invalid/x.git", "abc", []}
      assert %{lock: {:differs, %{element: :shape}}} = fields({@vsn, Hex.SCM, git})
    end
  end

  # #162: the compile env is the other cause of "the dependency compile environment is
  # outdated", read from the build's own `.app` the way Mix reads it.
  describe "compile_env/2 and compile_env_differences/1" do
    setup do
      build = Path.join(System.tmp_dir!(), "cenv-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(build, "ebin"))
      on_exit(fn -> File.rm_rf!(build) end)
      on_exit(fn -> Application.delete_env(:a_fake_dep, :a_setting, persistent: true) end)
      %{build: build}
    end

    defp app_file(build, app, properties) do
      File.write!(
        Path.join([build, "ebin", "#{app}.app"]),
        :io_lib.format(~c"~p.", [{:application, app, properties}]) |> IO.iodata_to_binary()
      )
    end

    test "entries are read from the .app", ctx do
      entries = [{:a_fake_dep, [:a_setting], {:ok, true}}]
      app_file(ctx.build, :some_dep, vsn: ~c"1.0.0", compile_env: entries)

      assert Manifest.compile_env(ctx.build, :some_dep) == {:ok, entries}
    end

    test "no .app is :absent, and an .app recording none is :absent too", ctx do
      assert Manifest.compile_env(ctx.build, :some_dep) == :absent

      app_file(ctx.build, :some_dep, vsn: ~c"1.0.0")
      assert Manifest.compile_env(ctx.build, :some_dep) == :absent
    end

    # Mix answers :invalid for a bad file and :missing for none; depdep keeps them
    # apart, as `read/1` does for the compile manifest, because the causes differ.
    @tag verifies: "compile-env-read-from-the-app"
    test "a file that is not the term Mix writes is :unreadable", ctx do
      File.write!(Path.join([ctx.build, "ebin", "some_dep.app"]), "not a term at all")
      assert Manifest.compile_env(ctx.build, :some_dep) == :unreadable
    end

    test "an entry agreeing with the application env is not a difference" do
      Application.put_env(:a_fake_dep, :a_setting, true, persistent: true)

      assert Manifest.compile_env_differences([{:a_fake_dep, [:a_setting], {:ok, true}}]) == []
    end

    @tag verifies: "explain-rebuilt-names-the-compile-env"
    test "an entry disagreeing is named with both values" do
      Application.put_env(:a_fake_dep, :a_setting, false, persistent: true)

      assert Manifest.compile_env_differences([{:a_fake_dep, [:a_setting], {:ok, true}}]) ==
               [{:a_fake_dep, [:a_setting], {:ok, true}, {:ok, false}}]
    end

    # The shape #141 produced on every run: recorded a value, and the asking VM has
    # none because the member's config was never loaded.
    test "an unset current value is a difference, reported as :error" do
      assert Manifest.compile_env_differences([{:a_fake_dep, [:a_setting], {:ok, true}}]) ==
               [{:a_fake_dep, [:a_setting], {:ok, true}, :error}]
    end

    # `Config.Provider` rescues an inaccessible value to `false`; this reports it as a
    # difference instead, which is true and needs no rescue.
    test "a value that cannot be traversed is a difference, not a crash" do
      Application.put_env(:a_fake_dep, :a_setting, :not_accessible, persistent: true)

      assert Manifest.compile_env_differences([{:a_fake_dep, [:a_setting, :deeper], {:ok, 1}}]) ==
               [{:a_fake_dep, [:a_setting, :deeper], {:ok, 1}, :error}]
    end
  end

  describe "read/1 distinguishes absent from unreadable, without rescue" do
    setup do
      dir = Path.join(System.tmp_dir!(), "manifest-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "no manifest is :absent — Mix's own :error branch, a different cause", ctx do
      assert Manifest.read(ctx.dir) == :absent
    end

    test "a file that is not an Erlang term at all is :unreadable", ctx do
      write(ctx.dir, "this is not a term")
      assert Manifest.read(ctx.dir) == :unreadable
    end

    @tag verifies: "manifest-comparison-names-the-element"
    test "a term of the wrong shape is :unreadable, not an invented answer", ctx do
      write(ctx.dir, :erlang.term_to_binary({:something, :else}))
      assert Manifest.read(ctx.dir) == :unreadable
    end

    test "the term Mix writes reads back as its three compared values", ctx do
      write(ctx.dir, :erlang.term_to_binary({2, @vsn, Hex.SCM, @lock}))
      assert Manifest.read(ctx.dir) == {:ok, {@vsn, Hex.SCM, @lock}}
    end

    @tag verifies: "manifest-comparison-names-the-element"
    test "path/1 is where Mix keeps it, so a reader can fetch it themselves", ctx do
      assert Manifest.path(ctx.dir) == Path.join([ctx.dir, ".mix", "compile.elixir_scm"])
    end

    defp write(dir, contents) do
      File.mkdir_p!(Path.join(dir, ".mix"))
      File.write!(Path.join([dir, ".mix", "compile.elixir_scm"]), contents)
    end
  end
end
