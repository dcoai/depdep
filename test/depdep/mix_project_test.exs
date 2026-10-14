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
             ~w(lib priv guide mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
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
    # The guide is numbered and `Path.wildcard/1` sorts, so hexdocs lists the
    # pages in reading order. The README stays first and the changelog last.
    extras = project()[:docs][:extras]
    assert hd(extras) == "README.md"
    assert List.last(extras) == "CHANGELOG.md"
    assert Enum.slice(extras, 1..-2//1) == Path.wildcard("guide/[0-9]*.md")
    refute Enum.empty?(Path.wildcard("guide/[0-9]*.md"))
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
  # **The rule is about what a reader must be able to REACH, not every mention of a
  # private host** (#217). `@source_url` is published twice over — Hex renders it as the
  # package's `Source` link, and ExDoc builds every per-function source link from it — so
  # a private address there is a 404 for everyone off this network. That shipped for
  # several releases while this test passed, because it read `README.md` and nothing else.
  #
  # Derived from `project/0` and `package/0`, so a link added later cannot escape it. Same
  # correction as #185 (the shipped-file guard derived from `package/0`) and #192 (install
  # snippets derived from `@version`): replace a reminder with a derivation.
  #
  # **Prose is deliberately not covered.** `CHANGELOG.md` and `lib/depdep/profile.ex` each
  # name `cn2` in a record of what a metrics instance held. Those are records, not
  # instructions, and they hand nobody a link to fail on — the same argument #192 wrote
  # down for release numbers in prose, which a guard must not rewrite.
  test "nothing a reader outside the private network must reach names it" do
    private = ["conet.yarina.org", "dco-tek"]

    readme = File.read!("README.md")
    for host <- private, do: refute(readme =~ host, "README.md names #{host}")

    config = Mix.Project.config()

    for host <- private do
      refute config[:source_url] =~ host,
             "source_url names #{host} — Hex publishes it as the package's Source link " <>
               "and ExDoc builds every source link from it (#217)"
    end

    for {name, url} <- config[:package][:links], host <- private do
      refute url =~ host, "package link #{inspect(name)} names #{host} (#217)"
    end

    [first_install | _] = Regex.scan(~r/Mix\.install\(\[\{:depdep, ([^}]+)\}\]\)/, readme)
    assert [_, ~s("~> ) <> _] = first_install
  end

  # **An install snippet must name the version this build ships** (#192, for #190).
  #
  # The check above asserts the README's first install form is a hex requirement rather
  # than a git ref (#76) — and says nothing about WHICH version, so `~> 0.1` passed. That
  # is how the README came to say `~> 0.10` and the guide `~> 0.9` and `tag: "v0.9.0"`
  # while the project shipped v0.11.0: a reader following the guide pinned a release the
  # project had since fixed twice.
  #
  # Derived from @version, so a release bump fails here until the docs follow. A reminder
  # does not work; the guard above proves it.
  #
  # **Install snippets only, never prose.** CHANGELOG.md names v0.9.0, v0.6.0 and every
  # other release, and the README cites releases by number in its history. Those are
  # records, and a guard that rewrote them to match the current version would be deleted
  # by the first person a release annoyed — which is worse than no guard.
  test "every install snippet in shipped markdown names this version" do
    version = Mix.Project.config()[:version]
    [major, minor, _patch] = String.split(version, ".")
    requirement = ~s("~> #{major}.#{minor}")

    for page <- shipped_markdown(), body = File.read!(page) do
      for [snippet, spec] <- Regex.scan(~r/(Mix\.install\(\[\{:depdep, [^}]+\}\]\))/, body) do
        cond do
          String.contains?(spec, "~>") ->
            assert String.contains?(spec, requirement),
                   "#{page}: #{String.trim(snippet)} should require #{requirement}"

          String.contains?(spec, "tag:") ->
            assert String.contains?(spec, ~s(tag: "v#{version}")),
                   "#{page}: #{String.trim(snippet)} should pin tag: \"v#{version}\""

          true ->
            :ok
        end
      end
    end
  end

  # Every markdown file the package ships appears on hexdocs beside the README, so
  # the same rule binds all of it. **The subjects are DERIVED from `package/0`,
  # not listed** (#185, for #184): this check named the README, then gained the
  # guide when the guide was created, and a third shipped file — CHANGELOG.md —
  # was never added, so the private group reached hexdocs in four places. A guard
  # that enumerates what it covers goes stale every time the package grows, which
  # is this defect's whole mechanism.
  #
  # A `.md` filter over `files:` is NOT enough: `guide` is a DIRECTORY, so
  # filtering alone would silently drop every guide page and quietly remove the
  # coverage this test used to have. Directory entries are expanded.
  test "no shipped markdown points at the private host or group" do
    pages = shipped_markdown()

    assert "README.md" in pages
    assert "CHANGELOG.md" in pages

    assert Enum.any?(pages, &String.starts_with?(&1, "guide/")),
           "the guide ships but no page was derived — a directory entry was not expanded, " <>
             "which is exactly the regression this derivation exists to prevent"

    for page <- pages do
      body = File.read!(page)
      refute body =~ "conet.yarina.org", "#{page} names the private host"
      refute body =~ "dco-tek", "#{page} names the private group"
    end
  end

  # The markdown `package/0` ships, with directory entries expanded. `files:` holds
  # a mix of files and directories, which is why this cannot be a filter.
  defp shipped_markdown do
    Mix.Project.config()[:package][:files]
    |> Enum.flat_map(fn entry ->
      cond do
        File.dir?(entry) -> Path.wildcard(Path.join(entry, "**/*.md"))
        String.ends_with?(entry, ".md") -> [entry]
        true -> []
      end
    end)
    |> Enum.sort()
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

  # #148. depdep's own CI points at a throwaway store with `DEPDEP_STORE`, while
  # the dco-tek group defines the SEPARATE variables unprotected and unscoped so
  # every consumer inherits one shared store. depdep refuses both forms at once
  # rather than guessing, so a job setting the URL form must get rid of the
  # inherited one.
  #
  # It must `unset` them, NOT set them to "" in `variables:`. **Project and group
  # CI variables take precedence over a job's own `variables:`** — documented
  # GitLab behaviour, and the opposite of the intuition. The first fix for this
  # used `DEPDEP_ACCESS_KEY: ""` and changed nothing: the job still saw the
  # group's value, and the pipeline failed the same way. This test asserts the
  # form that works, so that mistake cannot come back.
  #
  # A test rather than a CI-only check, for the reason #124's is: the next group
  # variable someone adds for another project should break this on a developer's
  # machine, not three steps downstream in a pipeline.
  test "every job that sets DEPDEP_STORE unsets the inherited separate variables" do
    ci = File.read!(".gitlab-ci.yml")

    jobs =
      ci
      |> String.split(~r/^[ \t]*variables:[ \t]*$/m)
      |> Enum.drop(1)
      |> Enum.filter(&(&1 =~ "DEPDEP_STORE:"))

    assert jobs != [], "no job sets DEPDEP_STORE — has .gitlab-ci.yml moved?"

    # The list `Depdep.S3` treats as the separate form. DEPDEP_SECRET_KEY is not one
    # of them: both forms use it, so unsetting it would break the job it belongs to.
    separate = ~w(DEPDEP_ENDPOINT DEPDEP_BUCKET DEPDEP_ACCESS_KEY DEPDEP_REGION)

    unsets = Regex.scan(~r/^\s*- unset ([A-Z_ ]+)$/m, ci)
    assert length(unsets) >= length(jobs), "a job sets DEPDEP_STORE without an unset line"

    for [_, names] <- unsets, name <- separate do
      assert name in String.split(names),
             "an unset line omits #{name}. depdep refuses two config forms (#148), " <>
               "and the group defines these for every project."
    end

    refute ci =~ ~r/^\s*DEPDEP_(ENDPOINT|BUCKET|ACCESS_KEY|REGION):\s*""\s*$/m,
           "clearing a store variable in `variables:` does nothing — project and " <>
             "group variables outrank a job's own. Use `unset` (#148)."

    # The same trap caught the secret too, and far more quietly: the access key
    # made `one_form/0` refuse out loud, while the wrong secret only failed against
    # a server that checks signatures. adobe/s3mock does not, so the apt job passed
    # with the production secret; s3proxy does, so reclamation failed with
    # SignatureDoesNotMatch. A job must export its own secret, not declare it.
    refute ci =~ ~r/^\s*DEPDEP_SECRET_KEY:\s/m,
           "DEPDEP_SECRET_KEY in `variables:` is inert — the group defines one and " <>
             "it outranks a job's own. Export it in before_script (#148)."

    for job <- jobs do
      assert job =~ "export DEPDEP_SECRET_KEY=",
             "a job sets DEPDEP_STORE without exporting its own DEPDEP_SECRET_KEY (#148)"
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

  # #202/#216. A `@tag verifies:` is a DECLARATION; the relation in the log is what
  # the triangle counts, and the two can disagree. Until surfex 0.9.0 only one
  # direction was reported, so the rule lived here as a shell line in the `surfex`
  # job — `mix surfex.suggest` piped through `grep -q '^verifies'` — and THIS test
  # guarded that line. 0.9.0 reports both directions itself (**Unrecorded**: a tag
  # naming a real unit with no relation, AND a tag left on a relation someone
  # retired), which is dco-tek/surfex#203, filed from here. Both the shell line and
  # the assertions that pinned its spelling are gone.
  #
  # What remains worth guarding is the line that now carries the rule. `mix
  # surfex.status` is the whole gate — relations, Unrecorded, Broken, Undeclared,
  # Triangle — and nothing else in this suite asserts the job runs it. The check
  # cannot run inside `mix test`, because a nested `mix` contends for the build
  # lock, so without an assertion here, dropping it from CI would be invisible
  # until a relation went wrong. Same reason as #124's and #148's CI-shape tests
  # above: a CI-only invariant needs an assertion a developer can break at their
  # desk.
  test "the surfex job still runs the gate that reports an unrecorded declaration" do
    ci = File.read!(".gitlab-ci.yml")

    [_, job] = String.split(ci, ~r/^surfex:$/m, parts: 2)
    job = job |> String.split(~r/^[a-z][a-z0-9-]*:$/m) |> hd()

    assert job =~ ~r/^\s*- mix surfex\.status\s*$/m,
           "the surfex job no longer runs `mix surfex.status`, so NOTHING checks the " <>
             "relation log — a `@tag verifies:` with no relation, a tag on a retired " <>
             "relation, a dangling relation and a broken chain all go silent (#216)"

    assert job =~ ~r/^\s*- mix surfex\.log --verify\s*$/m,
           "the surfex job no longer verifies the log chain, so an edited line or a " <>
             "bad merge resolution is silent (#216)"

    # The gate must be the job's own failure, not an advisory print. `allow_failure`
    # on this job would make every check above it decorative — the exact shape
    # #208 is about on the evidence side.
    refute job =~ ~r/allow_failure:\s*true/,
           "the surfex job allows failure, so the relation gate reports without " <>
             "holding anything (#216)"
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
