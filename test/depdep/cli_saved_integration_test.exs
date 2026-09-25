defmodule Depdep.CLISavedIntegrationTest do
  @moduledoc """
  A compile time travels with the object and comes back as `saved` — end to
  end, against `Depdep.FakeStore`, in a real `elixir` process (#66).

  The fixture is one hex dependency with a built tree on disk. `--push` sends
  it with the compile time a `--compile-deps` would have left beside it; a
  cold checkout `--pull`s it back and reports what the hit saved; a warm one
  reports the same from the note alone, with no request.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Depdep.FakeStore

  @lock """
  %{
    "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"}
  }
  """

  setup do
    base = Path.join(System.tmp_dir!(), "depdep-saved-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {agent, port} = FakeStore.start()
    %{base: base, store: agent, port: port}
  end

  # A project directory with the lock, and optionally jason's two trees.
  defp project(base, name, built?) do
    dir = Path.join(base, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.lock"), @lock)

    if built? do
      File.mkdir_p!(Path.join([dir, "deps", "jason", "lib"]))
      File.mkdir_p!(Path.join([dir, "_build", "test", "lib", "jason", "ebin"]))
      File.write!(Path.join([dir, "deps", "jason", "lib", "jason.ex"]), "source")
      File.write!(Path.join([dir, "_build", "test", "lib", "jason", "ebin", "j.beam"]), "beam")
    end

    dir
  end

  defp depdep(dir, port, args) do
    System.cmd(
      "elixir",
      ["-pa", Application.app_dir(:depdep, "ebin"), "-e", "Depdep.CLI.main(System.argv())", "--"] ++
        ["--project", "." | args],
      cd: dir,
      env: [
        {"DEPDEP_ENDPOINT", "http://127.0.0.1:#{port}"},
        {"DEPDEP_BUCKET", "bucket"},
        {"DEPDEP_ACCESS_KEY", "key"},
        {"DEPDEP_SECRET_KEY", "secret"}
      ],
      stderr_to_stdout: true
    )
  end

  defp metrics(dir), do: JSON.decode!(File.read!(Path.join(dir, "metrics.json")))

  defp only_unit(dir), do: metrics(dir)["phases"] |> hd() |> Map.fetch!("units") |> hd()

  test "push carries the compile time; a cold pull reports what it saved", ctx do
    builder = project(ctx.base, "builder", true)
    File.mkdir_p!(Path.join([builder, "_build", "test", ".depdep"]))
    File.write!(Path.join([builder, "_build", "test", ".depdep", "jason.compile"]), "2500000")

    assert {out, 0} = depdep(builder, ctx.port, ["--push"])
    assert out =~ "uploaded 1"

    [{path, {_bytes, metadata}}] =
      ctx.store
      |> FakeStore.objects()
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "v3/") end)

    assert metadata == %{"compile-us" => "2500000"}
    assert path =~ "jason"

    # A cold checkout: nothing on disk but the lock.
    cold = project(ctx.base, "cold", false)
    assert {out, 0} = depdep(cold, ctx.port, ["--pull", "--metrics", "metrics.json"])
    assert out =~ "pulled 1"
    assert out =~ ~r/saved ~2\.[0-9]s/

    assert File.read!(Path.join([cold, "_build", "test", ".depdep", "jason.compile"])) ==
             "2500000"

    unit = only_unit(cold)
    assert unit["saved_us"] > 2_000_000 and unit["saved_us"] <= 2_500_000
    assert unit["compile_us"] == nil, "a restored unit was not compiled here"
    assert metrics(cold)["saved_total_us"] == unit["saved_us"]

    # #101: the object's own number, before the transfer is subtracted — so a
    # pulled unit carries both, and the carried one is the larger.
    assert unit["compile_carried_us"] == 2_500_000
    assert unit["compile_carried_us"] >= unit["saved_us"]

    # The push's offer (HEAD, then PUT), then the pull's GET and the one HEAD
    # that reads the compile time back — for the one unit that was fetched.
    methods =
      ctx.store
      |> FakeStore.requests()
      |> Enum.filter(fn {_, p, _} -> p == path end)
      |> Enum.map(&elem(&1, 0))

    assert methods == ["HEAD", "PUT", "GET", "HEAD"]

    # Warm: already present, the whole compile saved, and no request at all.
    before = length(FakeStore.requests(ctx.store))
    assert {out, 0} = depdep(cold, ctx.port, ["--pull", "--metrics", "metrics.json"])
    assert out =~ "already present 1"
    assert out =~ "saved ~2.5s"
    assert only_unit(cold)["saved_us"] == 2_500_000

    # A present unit reads the note beside the build, so it carries the same
    # number with no request at all.
    assert only_unit(cold)["compile_carried_us"] == 2_500_000

    after_ = ctx.store |> FakeStore.requests() |> Enum.drop(before)

    refute Enum.any?(after_, fn {_, p, _} -> p == path end),
           "a present unit asks the store nothing"
  end

  test "an object with no compile time reports nothing rather than zero", ctx do
    builder = project(ctx.base, "builder", true)
    assert {_, 0} = depdep(builder, ctx.port, ["--push"])

    cold = project(ctx.base, "cold", false)
    assert {out, 0} = depdep(cold, ctx.port, ["--pull", "--metrics", "metrics.json"])
    assert out =~ "pulled 1"
    refute out =~ "saved"

    assert only_unit(cold)["saved_us"] == nil
    assert metrics(cold)["saved_total_us"] == nil
  end
end
