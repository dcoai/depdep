defmodule Depdep.OperatorAimTest do
  @moduledoc """
  The fourth rail, in process (#150): `--confirm` must name the bucket it will
  change, and `Depdep.CLI.Operator.sweep/1` checks the name before it lists.

  In process rather than through `System.cmd`, for two reasons. It is the function
  under test, not the shell plumbing — `Depdep.CLISweepRailIntegrationTest` covers
  the invocation an operator types. And an out-of-process test cannot be traced to
  the code it exercises, so it can never be the evidence that validates a spec
  relation; this one can.
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
            {"DEPDEP_BUCKET", "the-real-store"},
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

  defp sweep(args) do
    {:ok, opts} = CLI.parse(["--sweep" | args])
    capture_io(:stderr, fn -> CLI.Operator.sweep(opts) end)
  end

  @tag verifies: "sweep-confirm-names-its-bucket"
  test "a --bucket that is not this store refuses, before the store is touched", ctx do
    output = sweep(["--confirm", "--bucket", "some-other-store"])

    assert output =~ "refusing to sweep"
    assert output =~ ~s(--bucket says "some-other-store")
    assert output =~ ~s(the store configured here is "the-real-store")

    # The rail's placement is the claim: before the listing, so a misaimed
    # invocation costs nothing. Asserted as "the store was never contacted".
    assert FakeStore.requests(ctx.store) == [],
           "the store was contacted despite the refusal: " <>
             inspect(FakeStore.requests(ctx.store))
  end

  test "a --bucket naming this store gets past the rail and reaches the store", ctx do
    output = sweep(["--confirm", "--bucket", "the-real-store"])

    # Past the fourth rail: no complaint about the name. What stops it instead is
    # the THIRD rail, on an empty store, which can only have fired after a listing.
    refute output =~ "--bucket says"
    assert output =~ "no root has been written"
    assert FakeStore.requests(ctx.store) != [], output
  end

  # The third rail as `sweep/1` implements it, which nothing covered before #150.
  # `Depdep.SweepTest` asserts `Sweep.current_roots/2` — the decision — but no test
  # exercised sweep/1's half: that it refuses on that answer and says where to look.
  # The gap surfaced when #150 changed sweep/1 and its `implements` relation to
  # `spec/08-reclamation.md#rails` dangled with no test able to re-validate it.
  @tag verifies: "sweep-refuses-without-roots"
  test "an empty store has no current roots, so sweep/1 refuses and says where to look", ctx do
    output = sweep(["--confirm", "--bucket", "the-real-store"])

    assert output =~ "refusing to sweep"
    assert output =~ "run --report first"
    assert output =~ "widen --within"

    # It got as far as the listing, so this is the third rail refusing on what the
    # store holds, not the fourth refusing on where it is aimed.
    assert FakeStore.requests(ctx.store) != []
    refute output =~ "--bucket says"
  end

  # A dry run changes nothing, so it needs no --bucket and the fourth rail lets it
  # through — it still meets the third, because the store is empty.
  test "a dry run is not stopped by the fourth rail", ctx do
    output = sweep([])

    refute output =~ "--bucket"
    assert output =~ "no root has been written"
    assert FakeStore.requests(ctx.store) != [], output
  end
end
