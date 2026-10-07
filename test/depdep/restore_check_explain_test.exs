defmodule Depdep.RestoreCheckExplainTest do
  @moduledoc """
  `--explain-rebuilt`'s lines, called directly (#135).

  The integration test drives the real binary in a subprocess, which is the right
  way to prove the flag reaches the output — but a subprocess call is invisible to
  static analysis, so nothing there can show that these lines come from
  `explain/1`. This does, and it is the cheaper test of the two to read.
  """
  use ExUnit.Case, async: true

  alias Depdep.RestoreCheck

  @vsn {System.version(), :erlang.system_info(:otp_release)}
  @lock {:hex, :telemetry, "1.3.0", "inner", [:mix], [], "hexpm", "outer"}

  setup do
    dir = Path.join(System.tmp_dir!(), "explain-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, term) do
    File.mkdir_p!(Path.join(dir, ".mix"))
    File.write!(Path.join([dir, ".mix", "compile.elixir_scm"]), :erlang.term_to_binary(term))
  end

  defp evidence(dir, lock), do: %{build: dir, expected: {@vsn, Hex.SCM, lock}}

  @tag verifies: "explain-rebuilt-names-the-field"
  test "a differing lock names the field and the first differing element", ctx do
    write(ctx.dir, {2, @vsn, Hex.SCM, put_elem(@lock, 7, "other-outer")})

    lines = RestoreCheck.explain(evidence(ctx.dir, @lock))
    text = Enum.join(lines, "\n")

    assert text =~ "compile.elixir_scm"
    assert text =~ "elixir/otp  same"
    assert text =~ "scm         same"
    assert text =~ "lock        DIFFERS"
    assert text =~ "first differing tuple element: 7"
  end

  test "an absent manifest says so, which Mix's own message cannot", ctx do
    assert [line] = RestoreCheck.explain(evidence(ctx.dir, @lock))
    assert line =~ "ABSENT, so Mix recompiles"
  end

  # Since #162 the agreeing case says what it looked at NEXT, because the compile env is
  # the other cause of Mix's sentence and saying only "another reason" is what left #141
  # to be diagnosed by reading Mix's source.
  test "a manifest that agrees says so, and then what else it looked at", ctx do
    write(ctx.dir, {2, @vsn, Hex.SCM, @lock})

    lines = RestoreCheck.explain(evidence(ctx.dir, @lock))

    assert Enum.join(lines, "\n") =~ "every field agrees"
    assert List.last(lines) =~ "the rebuild is for another reason"
  end

  # #162. The comparison is captured during the converge, while the member's config is
  # loaded, so by the time this prints it is a recorded fact rather than a fresh lookup.
  @tag verifies: "explain-rebuilt-names-the-compile-env"
  test "a differing compile env names the entry and both values", ctx do
    write(ctx.dir, {2, @vsn, Hex.SCM, @lock})

    evidence =
      evidence(ctx.dir, @lock)
      |> Map.put(:compile_env, [
        {:phoenix_live_view, [:enable_expensive_runtime_checks], {:ok, false}, {:ok, true}}
      ])

    text = RestoreCheck.explain(evidence) |> Enum.join("\n")

    assert text =~ "compile env: {:phoenix_live_view, :enable_expensive_runtime_checks}"
    assert text =~ "was false, is true"
    refute text =~ "another reason", "it had a reason; it must not also shrug"
  end

  test "an unset current value reads as unset rather than as :error", ctx do
    write(ctx.dir, {2, @vsn, Hex.SCM, @lock})

    evidence =
      evidence(ctx.dir, @lock)
      |> Map.put(:compile_env, [{:some_app, [:a_key], {:ok, 1}, :error}])

    assert RestoreCheck.explain(evidence) |> Enum.join("\n") =~ "was 1, is unset"
  end

  test "an unreadable .app says so rather than naming nothing", ctx do
    write(ctx.dir, {2, @vsn, Hex.SCM, @lock})

    evidence = evidence(ctx.dir, @lock) |> Map.put(:compile_env, :unreadable)

    assert RestoreCheck.explain(evidence) |> Enum.join("\n") =~
             "the .app file is not the term Mix writes"
  end

  test "no evidence is no explanation rather than a crash" do
    assert RestoreCheck.explain(%{}) == []
  end
end
