defmodule Depdep.MixProjectTest do
  # The package is what a hex install of depdep receives, and `mix hex.build`
  # only checks that the fields it needs exist. What they say is decided here.
  use ExUnit.Case, async: true

  defp project, do: Depdep.MixProject.project()

  test "the package is MIT, links its source, and lists its files explicitly" do
    package = project()[:package]
    assert package[:licenses] == ["MIT"]
    assert %{"Source" => "https://" <> _} = package[:links]

    assert package[:files] ==
             ~w(lib priv mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
  end

  test "every listed file exists, and the license and changelog are what they claim" do
    for file <- project()[:package][:files],
        do: assert(File.exists?(file), "#{file} is listed but absent")

    assert File.read!("LICENSE") =~ "MIT License"
    assert File.read!("CHANGELOG.md") =~ "## v#{project()[:version]} —"
  end

  # `mix hex.publish` builds docs by running the `docs` task. With no ex_doc
  # dependency allowed, that task is an alias over the escript — and the
  # README is its front page, the changelog beside it (#77).
  test "docs are an alias, with the README as the main page" do
    assert is_function(project()[:aliases][:docs], 1)
    assert project()[:docs][:main] == "readme"
    assert project()[:docs][:extras] == ["README.md", "CHANGELOG.md"]
  end

  # The escript is installed by hand, so its absence is the likeliest way
  # `mix docs` fails on a fresh machine; the failure has to say what to run.
  #
  # The throwaway `MIX_HOME` needs hex installed into it, and that is new (#129).
  # While surfex was a GIT dependency its SCM was built into Mix, so an empty home
  # was enough. A HEX dependency's SCM comes from hex itself, so Mix cannot even
  # load the project without it and stops to ask whether to install it — which in
  # CI means blocking on stdin until the test times out. A fresh machine for
  # depdep has hex by definition (nothing could be fetched without it), so
  # installing it here models the intended scenario rather than working around it:
  # a machine with hex and no ex_doc escript.
  @tag :integration
  test "mix docs without the escript names the install command" do
    home = Path.join(System.tmp_dir!(), "depdep-mixhome-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    env = [{"MIX_HOME", home}]

    assert {_, 0} = System.cmd("mix", ["local.hex", "--force"], env: env, stderr_to_stdout: true)

    assert {output, 1} = System.cmd("mix", ["docs"], env: env, stderr_to_stdout: true)

    assert output =~ "run: mix escript.install hex ex_doc --force"
  end

  # The README is the package's front page on hexdocs. A reader there has no
  # dco-tek credential, so nothing in it may point at the private host, and the
  # first install form has to be the one that works from hex (#76).
  test "the README is written for a reader outside the private network" do
    readme = File.read!("README.md")
    refute readme =~ "conet.yarina.org"
    refute readme =~ "dco-tek"

    [first_install | _] = Regex.scan(~r/Mix\.install\(\[\{:depdep, ([^}]+)\}\]\)/, readme)
    assert [_, ~s("~> ) <> _] = first_install
  end

  # spec/01-goals-and-scope.md#zero-runtime-deps. Depdep runs before
  # `mix deps.get`, so a RUNTIME dependency would have to be fetched by the
  # machinery it exists to get in front of.
  #
  # This used to assert `deps == []`, which is a proxy: it was true, and it was
  # not the constraint. The constraint is that nothing here can reach a consumer
  # or be needed to run, and it is what surfex is allowed to be under (#113).
  # An empty list still passes; `{:jason, "~> 1.4"}` does not.
  @tag verifies: "zero-runtime-deps-guarded"
  test "every dependency is build-time only and reaches no consumer" do
    for dep <- project()[:deps] do
      {app, opts} =
        case dep do
          {app, opts} when is_list(opts) -> {app, opts}
          {app, req} when is_binary(req) -> {app, []}
          {app, req, opts} when is_binary(req) and is_list(opts) -> {app, opts}
        end

      assert Keyword.get(opts, :runtime) == false,
             "#{app} must be runtime: false — depdep runs before mix deps.get"

      only = opts |> Keyword.get(:only, []) |> List.wrap()

      assert only != [],
             "#{app} must be only: [:dev, :test] — an unrestricted dep is transitive"

      assert only -- [:dev, :test] == [],
             "#{app} may only be :dev or :test, not #{inspect(only -- [:dev, :test])}"
    end
  end

  # #124. depdep gained its first dependency in #113, and `mix deps.get` went
  # into the `default:` `before_script`. A job that defines its OWN
  # `before_script` replaces the default's rather than extending it, so two jobs
  # silently stopped fetching — and the pipeline stayed green once on a cache hit
  # before failing. A cache is an optimisation and must never be load-bearing for
  # correctness.
  #
  # A test rather than a CI-only check, so adding a job with its own
  # `before_script` fails on a developer's machine rather than intermittently in
  # a pipeline months later.
  test "every before_script in CI fetches dependencies" do
    blocks =
      ".gitlab-ci.yml"
      |> File.read!()
      |> String.split(~r/^[ \t]*before_script:[ \t]*$/m)
      |> Enum.drop(1)

    assert blocks != [], "no before_script found — has .gitlab-ci.yml moved?"

    for block <- blocks do
      # The block's own lines: list items, comments and blanks, up to the first
      # line that starts a sibling or parent key.
      own =
        block
        |> String.split("\n")
        |> Enum.drop_while(&(String.trim(&1) == ""))
        |> Enum.take_while(fn line ->
          trimmed = String.trim(line)
          trimmed == "" or String.starts_with?(trimmed, ["-", "#"])
        end)
        |> Enum.join("\n")

      assert own =~ "mix deps.get",
             "a before_script does not fetch dependencies. A job overriding " <>
               "before_script must repeat the fetch (#124):\n" <> own
    end
  end

  # The tarball is the package: build it and read back what it holds, so a
  # directory added to the tree does not silently ship or silently not.
  @tag :integration
  test "mix hex.build ships lib, priv, the profile and the metadata files, and nothing else" do
    out = Path.join(System.tmp_dir!(), "depdep-hex-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(out) end)

    assert {output, 0} =
             System.cmd("mix", ["hex.build", "--unpack", "--output", out],
               env: [{"MIX_ENV", "prod"}],
               stderr_to_stdout: true
             )

    assert output =~ "priv/profiles/depdep.exs"

    shipped =
      Path.wildcard(Path.join(out, "**"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, out))
      |> Enum.sort()

    assert "priv/profiles/depdep.exs" in shipped
    assert "lib/depdep/profile.ex" in shipped
    assert "lib/mix/tasks/depdep.profile.ex" in shipped

    for file <- ~w(mix.exs README.md LICENSE CHANGELOG.md .formatter.exs),
        do: assert(file in shipped)

    refute Enum.any?(shipped, &String.starts_with?(&1, "test/"))
    refute ".gitlab-ci.yml" in shipped
    refute Enum.any?(shipped, &String.starts_with?(&1, "_build/"))

    # spec/01-goals-and-scope.md#zero-runtime-deps: the spec, the relation log
    # and its config are depdep's own working material and are not a consumer's
    # business. `package/0`'s `files` list is explicit, so this asserts that the
    # list was not widened rather than that hex guessed well (#113).
    refute Enum.any?(shipped, &String.starts_with?(&1, "spec/"))
    refute ".surfex.exs" in shipped
    refute "RELATIONS.md" in shipped
    refute Enum.any?(shipped, &String.starts_with?(&1, ".surfex/"))
  end

  # spec/01-goals-and-scope.md#zero-runtime-deps: "a published package of depdep
  # declares no dependencies, whatever `deps/0` holds for depdep's own
  # development." The two tests above check the shape of `deps/0` and what the
  # tarball carries; this one checks the claim a consumer actually depends on,
  # which is hex's own requirements list.
  @tag :integration
  test "the built package declares no dependencies to hex" do
    dir = Path.join(System.tmp_dir!(), "depdep-hexmeta-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    tarball = Path.join(dir, "depdep.tar")

    assert {_output, 0} =
             System.cmd("mix", ["hex.build", "--output", tarball],
               env: [{"MIX_ENV", "prod"}],
               stderr_to_stdout: true
             )

    # `metadata.config` is inside the outer tar, beside contents.tar.gz — it is
    # not among the files `--unpack` writes out, so read it from the tarball.
    {:ok, [{_, metadata}]} =
      :erl_tar.extract(String.to_charlist(tarball), [:memory, {:files, [~c"metadata.config"]}])

    consultable = Path.join(dir, "metadata.config")
    File.write!(consultable, metadata)
    {:ok, terms} = :file.consult(String.to_charlist(consultable))

    # Found, not defaulted: if hex ever renames the key, this test must fail
    # loudly rather than pass on an absent one.
    assert {_, requirements} = List.keyfind(terms, "requirements", 0),
           "metadata.config has no requirements key — hex's format changed"

    assert requirements == [],
           "the package declares #{inspect(requirements)} — a consumer would inherit it, " <>
             "so a dev/test dep has reached hex metadata"
  end
end
