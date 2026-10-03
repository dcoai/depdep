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

  test "a manifest that agrees says the rebuild is for another reason", ctx do
    write(ctx.dir, {2, @vsn, Hex.SCM, @lock})

    assert [line] = RestoreCheck.explain(evidence(ctx.dir, @lock))
    assert line =~ "every field agrees"
  end

  test "no evidence is no explanation rather than a crash" do
    assert RestoreCheck.explain(%{}) == []
  end
end
