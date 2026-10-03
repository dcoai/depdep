defmodule Depdep.RestoreCheckTest do
  use ExUnit.Case, async: true

  alias Depdep.{Metrics, RestoreCheck}

  defp unit(name, bucket, extra \\ []),
    do: struct(%Metrics.Unit{provider: "mix", label: "app/#{name}", bucket: bucket}, extra)

  # What `statuses/2` now attaches to a rebuild verdict for `--explain-rebuilt`
  # (#135). These tests are about re-bucketing, so its contents do not matter
  # here — but the verdict has one shape, so they carry it.
  defp evidence, do: %{build: "_build/test/lib/x", expected: {{"1.20.4", ~c"29"}, Hex.SCM, nil}}

  defp phase(units),
    do: %Metrics.Phase{
      provider: "mix",
      direction: :pull,
      span_us: 10,
      concurrency: 8,
      units: units
    }

  # uficap's shape (#85): mint restored, Mix would rebuild it, req compiled
  # against it and failed. The restore has to become a miss, with the reason.
  @tag verifies: "restore-check-rebuckets"
  test "a restored unit Mix would rebuild is a miss with Mix's reason, and loses its saved time" do
    phase =
      phase([unit("mint", :pulled, saved_us: 5_000), unit("req", :missing, reason: "not found")])

    verdicts = %{
      "app/mint" => {:rebuild, "the dependency build is outdated", evidence()},
      "app/req" => :ok
    }

    {phase, rebuilt} = RestoreCheck.apply(phase, verdicts)

    assert [
             %Metrics.Unit{
               label: "app/mint",
               bucket: :missing,
               rebuilt: true,
               saved_us: nil,
               reason: reason
             },
             _
           ] =
             phase.units

    assert reason == "rebuilt — the dependency build is outdated"
    assert rebuilt == [{"app/mint", reason}]
    assert phase.tally == %{missing: 2}
    assert RestoreCheck.count([phase]) == 1
  end

  test "a present unit Mix would rebuild is a miss too" do
    {phase, rebuilt} =
      RestoreCheck.apply(phase([unit("jason", :present)]), %{
        "app/jason" => {:rebuild, "x", evidence()}
      })

    assert [%Metrics.Unit{bucket: :missing, rebuilt: true}] = phase.units
    assert length(rebuilt) == 1
  end

  test "ok verdicts, absent verdicts and non-restored buckets are left alone" do
    units = [
      unit("jason", :pulled, saved_us: 1),
      unit("ex_doc", :not_for_env),
      unit("forked", :skipped, reason: "git"),
      unit("plug", :missing, reason: "not found")
    ]

    verdicts = %{
      "app/jason" => :ok,
      "app/plug" => {:rebuild, "irrelevant: it is a miss already", evidence()}
    }

    {phase, rebuilt} = RestoreCheck.apply(phase(units), verdicts)

    assert phase.units == units
    assert rebuilt == []
    assert RestoreCheck.count([phase]) == 0
  end
end
