defmodule Depdep.CLIAptPushIntegrationTest do
  @moduledoc """
  The first `.deb` a store ever sees is uploaded, not a crash (#85, from
  uficap's first pipeline). A push from the archives directory needs no apt on
  the machine — a file ending in `.deb` is a unit — so this runs anywhere,
  against `Depdep.FakeStore`, in a real `elixir` process like the mix
  provider's end-to-end tests.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Depdep.FakeStore

  setup do
    base = Path.join(System.tmp_dir!(), "depdep-aptpush-#{System.unique_integer([:positive])}")
    archives = Path.join(base, "archives")
    File.mkdir_p!(archives)
    File.write!(Path.join(archives, "libbsd0_0.11.7-2_amd64.deb"), "not really a deb")
    on_exit(fn -> File.rm_rf!(base) end)
    {agent, port} = FakeStore.start()
    %{base: base, archives: archives, store: agent, port: port}
  end

  defp depdep(dir, port, args) do
    System.cmd(
      "elixir",
      ["-pa", Application.app_dir(:depdep, "ebin"), "-e", "Depdep.CLI.main(System.argv())", "--"] ++
        args,
      cd: dir,
      env: [
        # The suite is hermetic: an ambient DEPDEP_STORE would make depdep
        # refuse both forms at once (#93), so clear it for the child.
        {"DEPDEP_STORE", nil},
        {"DEPDEP_ENDPOINT", "http://127.0.0.1:#{port}"},
        {"DEPDEP_BUCKET", "bucket"},
        {"DEPDEP_ACCESS_KEY", "key"},
        {"DEPDEP_SECRET_KEY", "secret"}
      ],
      stderr_to_stdout: true
    )
  end

  @tag verifies: "apt-first-sighting"
  test "a new .deb is uploaded and the run exits 0", ctx do
    {output, status} =
      depdep(ctx.base, ctx.port, ["--push", "--provider", "apt", "--apt-cache-dir", ctx.archives])

    assert status == 0, output
    refute output =~ "FunctionClauseError"
    assert output =~ "uploaded 1"

    assert Enum.any?(Map.keys(FakeStore.objects(ctx.store)), fn key ->
             String.contains?(key, "libbsd0_0.11.7-2_amd64.deb")
           end)
  end
end
