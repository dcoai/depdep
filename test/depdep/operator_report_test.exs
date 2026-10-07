defmodule Depdep.OperatorReportTest do
  @moduledoc """
  `spec/08-reclamation.md#report`: what `--report` answers.

  `Depdep.CLI.Operator.report/1` had **no test at all** before #159 — it was
  exercised only by the `reclamation` CI job, and the only thing accounting for it in
  the relation log was a false `implements` against `#warts`, which the section
  explicitly disclaims. Retiring that left the command an operator reads *before*
  deleting with neither a specification nor a test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Depdep.{CLI, FakeStore}

  setup do
    {agent, port} = FakeStore.start()

    previous =
      for {k, v} <- [
            {"DEPDEP_STORE", nil},
            {"DEPDEP_ENDPOINT", "http://127.0.0.1:#{port}"},
            {"DEPDEP_BUCKET", "a-store"},
            {"DEPDEP_ACCESS_KEY", "key"},
            {"DEPDEP_SECRET_KEY", "secret"}
          ] do
        was = System.get_env(k)
        if v, do: System.put_env(k, v), else: System.delete_env(k)
        {k, was}
      end

    on_exit(fn ->
      for {k, was} <- previous do
        if was, do: System.put_env(k, was), else: System.delete_env(k)
      end
    end)

    %{store: agent}
  end

  # The body goes to stdout and the refusals to stderr, so they are captured apart.
  defp body(args \\ []) do
    {:ok, opts} = CLI.parse(["--report" | args])
    capture_io(fn -> CLI.Operator.report(opts) end)
  end

  defp warning(args \\ []) do
    {:ok, opts} = CLI.parse(["--report" | args])
    capture_io(:stderr, fn -> CLI.Operator.report(opts) end)
  end

  @tag verifies: "spec/08-reclamation.md#report"
  test "an empty store is reported, and nothing is deleted", ctx do
    out = body()

    assert out =~ "roots"
    assert FakeStore.objects(ctx.store) == %{}, "a report must not change the store"

    # It read the store rather than refusing: the listing happened.
    assert Enum.any?(FakeStore.requests(ctx.store), fn {m, _, _} -> m == "GET" end)
  end

  # The rule everywhere else: an unreachable store is reported and the run exits 0.
  test "an unreadable store says so rather than raising" do
    System.put_env("DEPDEP_ENDPOINT", "http://127.0.0.1:1")

    out = warning()

    assert out =~ "could not list the store" or out =~ "not configured"
  end

  test "no credentials is reported, not a crash" do
    System.delete_env("DEPDEP_SECRET_KEY")

    out = warning()

    assert out =~ "store not configured"
    assert out =~ "nothing to report"
  end
end
