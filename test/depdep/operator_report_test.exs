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

  # #167, for #140. The report is the command read BEFORE deleting, so a retired schema's
  # figure must read as reclaimable rather than live. Printing a reachable count for one
  # invited an operator to read 1.2 GiB of dead weight as storage still in use — the
  # production report said "382 reachable" for v2, none of them requestable.
  @tag verifies: "report-marks-a-retired-schema-reclaimable"
  test "a retired schema's group says so, and prints no reachable count", ctx do
    retired = "#{hd(Depdep.Key.retired())}/jason/1.4.4/aaa.tar.gz"
    :ok = Depdep.S3.put(store_cfg(ctx), retired, write_tmp("some bytes"))

    out = body()

    assert out =~ "RETIRED schema, all reclaimable"

    retired_line =
      out |> String.split("\n") |> Enum.find(&String.contains?(&1, hd(Depdep.Key.retired())))

    refute retired_line =~ "reachable",
           "a reachable count for a retired schema reads as live demand, and there is none"
  end

  test "a current-schema group still reports its reachable count", ctx do
    live = "#{Depdep.Key.schema()}/jason/1.4.4/aaa.tar.gz"
    :ok = Depdep.S3.put(store_cfg(ctx), live, write_tmp("some bytes"))

    line =
      body()
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, Depdep.Key.schema() <> "\t"))

    assert line =~ "reachable"
    refute line =~ "RETIRED"
  end

  # **The recurrence guard** (#169, for #125). A listing holding every prefix at the
  # CURRENT schema, asserting one row per prefix and not one per package. The defect was
  # that `group/1` knew the literal `"v2"`: when the schema moved to `v3` the mix clause
  # stopped matching, the `provider/version` clause took over, and the production report
  # printed 128 rows where one belonged.
  #
  # Now the grouping asks `Sweep.rule_for/1`, whose `:mix` is the fall-through, so there is
  # no schema literal left to go stale — this test holds that property rather than the
  # spelling of any one schema.
  @tag verifies: "one-classification-for-report-and-sweep"
  test "every prefix is one group, whatever the schema is called", ctx do
    cfg = store_cfg(ctx)
    schema = Depdep.Key.schema()

    for key <- [
          "#{schema}/jason/1.4.4/aaa.tar.gz",
          "#{schema}/ash/3.0.0/bbb.tar.gz",
          "#{schema}/telemetry/1.2.0/ccc.tar.gz",
          "apt/v1/debian-bookworm/libbsd0_0.11.7-2_amd64.deb",
          "git/v1/some-repo/1700000000/mirror.tar.gz",
          "src/v1/some-repo/abc123/source.tar.gz"
        ] do
      :ok = Depdep.S3.put(cfg, key, write_tmp("bytes for #{key}"))
    end

    groups =
      body()
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "objects,"))
      |> Enum.map(&(&1 |> String.split("\t") |> hd() |> String.replace("depdep: ", "")))

    assert Enum.sort(groups) == Enum.sort([schema, "apt/v1", "git/v1", "src/v1"])

    # The defect itself: three packages under one schema must not be three rows.
    refute Enum.any?(groups, &String.starts_with?(&1, schema <> "/")),
           "the schema is grouped per package again — #{inspect(groups)}"
  end

  defp store_cfg(_ctx) do
    {:ok, cfg} = Depdep.S3.config()
    Depdep.S3.start()
    cfg
  end

  defp write_tmp(contents) do
    path = Path.join(System.tmp_dir!(), "rep-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
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
