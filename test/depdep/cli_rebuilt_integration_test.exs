defmodule Depdep.CLIRebuiltIntegrationTest do
  @moduledoc """
  A restored dependency Mix would rebuild is a miss, named with Mix's reason,
  and `--compile-deps` compiles it (#85, from uficap's first pipeline).

  End to end against `Depdep.FakeStore` in real `elixir` processes: checkout A
  pulls, fetches and compiles a git dependency, then its manifest is given a
  lock entry Mix will not accept, and A pushes. Checkout B pulls the object
  back — a hit — and the run has to notice that Mix disagrees.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Depdep.FakeStore

  setup do
    base =
      Path.join(System.tmp_dir!(), "depdep-restorecheck-#{System.unique_integer([:positive])}")

    upstream = Path.join(base, "forked")
    File.mkdir_p!(upstream)
    on_exit(fn -> File.rm_rf!(base) end)

    File.write!(Path.join(upstream, "mix.exs"), """
    defmodule Forked#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :forked, version: "0.1.0"]
    end
    """)

    File.mkdir_p!(Path.join(upstream, "lib"))

    File.write!(
      Path.join([upstream, "lib", "forked.ex"]),
      "defmodule Forked, do: def hi, do: :hi\n"
    )

    git = fn args -> {_, 0} = System.cmd("git", args, cd: upstream, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "forked"])

    {agent, port} = FakeStore.start()
    %{base: base, upstream: upstream, store: agent, port: port}
  end

  defp checkout(base, name, upstream) do
    dir = Path.join(base, name)
    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule RebuiltFixture#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :rebuilt_fixture, version: "0.1.0", deps: deps()]
      defp deps, do: [{:forked, git: "file://#{upstream}", branch: "main"}]
    end
    """)

    File.write!(Path.join(dir, "mix.lock"), "%{}\n")
    File.write!(Path.join([dir, "config", "config.exs"]), "import Config\n")
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
        {"DEPDEP_SECRET_KEY", "secret"},
        {"MIX_ENV", "test"}
      ],
      stderr_to_stdout: true
    )
  end

  test "a hit Mix would rebuild is counted as a miss, said, and compiled", ctx do
    a = checkout(ctx.base, "a", ctx.upstream)

    # A: cold. The git dependency is fetched and compiled by depdep itself.
    assert {out_a, 0} = depdep(a, ctx.port, ["--pull", "--mix-get", "--compile-deps"])
    assert out_a =~ "Generated forked app"
    refute out_a =~ "rebuilt"

    # Give the built tree a manifest Mix will refuse: the same file Mix reads
    # in Mix.Dep.Loader.validate_manifest/1, with a lock entry that is not
    # this project's. Then push it, so the store serves exactly that.
    manifest = Path.join([a, "_build", "test", "lib", "forked", ".mix", "compile.elixir_scm"])
    {vsn, toolchain, scm, _lock} = :erlang.binary_to_term(File.read!(manifest))

    stale =
      {:git, "file:///elsewhere/forked", "0000000000000000000000000000000000000000",
       [branch: "main"]}

    File.write!(manifest, :erlang.term_to_binary({vsn, toolchain, scm, stale}))

    assert {out_push, 0} = depdep(a, ctx.port, ["--push"])
    assert out_push =~ "uploaded 1"

    # B: the same project, cold. The pull is a hit; Mix would rebuild it.
    b = checkout(ctx.base, "b", ctx.upstream)
    File.cp!(Path.join(a, "mix.lock"), Path.join(b, "mix.lock"))

    assert {out_b, 0} = depdep(b, ctx.port, ["--pull", "--mix-get", "--compile-deps"])
    assert out_b =~ "./forked: restored, but Mix would rebuild it — rebuilt — "
    assert out_b =~ "counted as a miss"
    assert out_b =~ "Generated forked app"
    assert out_b =~ ~r/missing 1.*— rebuilt 1/
    refute out_b =~ "pulled 1"
  end

  test "a clean hit is a hit: no rebuilt clause, nothing compiled", ctx do
    a = checkout(ctx.base, "a", ctx.upstream)
    assert {_, 0} = depdep(a, ctx.port, ["--pull", "--mix-get", "--compile-deps"])
    assert {_, 0} = depdep(a, ctx.port, ["--push"])

    b = checkout(ctx.base, "b", ctx.upstream)
    File.cp!(Path.join(a, "mix.lock"), Path.join(b, "mix.lock"))

    assert {out_b, 0} = depdep(b, ctx.port, ["--pull", "--mix-get", "--compile-deps"])
    assert out_b =~ "pulled 1"
    refute out_b =~ "rebuilt"
    refute out_b =~ "Generated forked app"
  end
end
