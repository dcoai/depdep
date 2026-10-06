defmodule Depdep.CLISweepRailIntegrationTest do
  @moduledoc """
  The fourth rail (#150): `--confirm` must name the bucket it will change.

  The other three rails ask whether to delete, how recently anything was written,
  and whether anything is still alive. None asks *which store* — and that answer
  can arrive from an inherited environment variable, which is how the group's
  credentials reached depdep's own CI in #148.

  Run against `Depdep.FakeStore` in a real `elixir` process, because the rail has
  to hold for the CLI an operator actually types rather than for a function call.
  The store records its requests, so "nothing was removed" is asserted as *nothing
  was even listed*: the refusal happens before the store is touched at all.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Depdep.FakeStore

  setup do
    base = Path.join(System.tmp_dir!(), "depdep-rail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {agent, port} = FakeStore.start()
    %{base: base, store: agent, port: port}
  end

  defp depdep(dir, port, args) do
    System.cmd(
      "elixir",
      ["-pa", Application.app_dir(:depdep, "ebin"), "-e", "Depdep.CLI.main(System.argv())", "--"] ++
        args,
      cd: dir,
      env: [
        {"DEPDEP_STORE", nil},
        {"DEPDEP_ENDPOINT", "http://127.0.0.1:#{port}"},
        {"DEPDEP_BUCKET", "the-real-store"},
        {"DEPDEP_ACCESS_KEY", "key"},
        {"DEPDEP_SECRET_KEY", "secret"}
      ],
      stderr_to_stdout: true
    )
  end

  @tag verifies: "sweep-confirm-names-its-bucket"
  test "--confirm naming another bucket refuses, and touches nothing", ctx do
    {output, status} =
      depdep(ctx.base, ctx.port, ["--sweep", "--confirm", "--bucket", "some-other-store"])

    assert output =~ "refusing to sweep"
    assert output =~ ~s(--bucket says "some-other-store")
    assert output =~ ~s(the store configured here is "the-real-store")

    # Before the listing, not after it: a misaimed invocation costs nothing.
    assert FakeStore.requests(ctx.store) == [],
           "the store was contacted despite the refusal: #{inspect(FakeStore.requests(ctx.store))}"

    # A refusal to act on an ambiguous instruction is not a crash.
    assert status == 0, output
  end

  test "--confirm without --bucket refuses and names what is missing", ctx do
    {output, _status} = depdep(ctx.base, ctx.port, ["--sweep", "--confirm"])

    assert output =~ "--bucket"
    assert output =~ "name the store"
    assert FakeStore.requests(ctx.store) == []
  end

  test "--confirm naming this store gets past the rail and reaches the store", ctx do
    {output, status} =
      depdep(ctx.base, ctx.port, ["--sweep", "--confirm", "--bucket", "the-real-store"])

    # Past the fourth rail: no complaint about the name. What stops it instead is
    # the THIRD rail on an empty store, which can only fire after a listing.
    refute output =~ "--bucket says"
    assert output =~ "no root has been written"
    assert status == 0, output
    assert FakeStore.requests(ctx.store) != [], output
  end
end
