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
  @tag :integration
  test "mix docs without the escript names the install command" do
    home = Path.join(System.tmp_dir!(), "depdep-mixhome-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    assert {output, 1} =
             System.cmd("mix", ["docs"], env: [{"MIX_HOME", home}], stderr_to_stdout: true)

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

  # Depdep runs before `mix deps.get`; a dependency would have to be fetched by
  # the machinery it exists to get in front of (README, "Why no dependencies").
  test "there are no dependencies" do
    assert project()[:deps] == []
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
  end
end
