defmodule Depdep.MixProject do
  use Mix.Project

  # Moves in the same commit the release tag will point at. Nothing warns when a
  # tag and this disagree, and they did for two releases before being collapsed
  # back to one — see #40.
  @version "0.5.0"
  @source_url "https://gitlab.conet.yarina.org/dco-tek/depdep"

  def project do
    [
      app: :depdep,
      version: @version,
      elixir: "~> 1.15",
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Depdep",
      description: description(),
      source_url: @source_url,
      package: package(),
      aliases: [docs: &docs/1],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  # `:inets` for `:httpc`, `:ssl` for an https endpoint, `:crypto` for SHA-256
  # and the HMAC chain of AWS Signature v4, `:xmerl` to read a bucket listing.
  # `:erl_tar` is in `:stdlib`. All ship with OTP — none is a dependency in the
  # sense the empty `deps/0` below forbids.
  def application do
    [extra_applications: [:inets, :ssl, :crypto, :xmerl]]
  end

  # Fixtures for the key rules live in test/support so they can be shared between
  # test files without being compiled into the package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # DELIBERATELY EMPTY, AND IT HAS TO STAY THAT WAY.
  #
  # Depdep runs BEFORE `mix deps.get` — that is the whole point of it. A
  # dependency here would have to be fetched by the machinery this exists to
  # get in front of. Signature v4 is about sixty lines; `:httpc` and `:erl_tar`
  # ship with OTP. See README, "Why no dependencies".
  defp deps, do: []

  # What a hex package of depdep carries, listed rather than defaulted so the set
  # is a decision: `priv/` because the metresis profile lives there and a task
  # reads it at runtime (#74); no `test/`, no CI config. `links` reads the one
  # `@source_url` so pointing it at a public mirror is a one-line change (#73).
  defp package do
    [
      licenses: ["MIT"],
      links: %{"Source" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  # `mix docs` without ex_doc as a dependency. `mix hex.publish` builds docs by
  # running the `docs` task, and hex's own help says any library or an alias
  # will do — so this alias runs the ex_doc *escript* (`mix escript.install hex
  # ex_doc`) over the compiled beams, and `deps/0` above stays empty. The
  # escript has to be installed by hand, and says so when it is not.
  defp docs(_args) do
    Mix.Task.run("compile")
    escript = Path.join(Mix.path_for(:escripts), "ex_doc")

    File.exists?(escript) ||
      Mix.raise(
        "mix docs: #{escript} is not installed — run: mix escript.install hex ex_doc --force"
      )

    config = Path.join(Mix.Project.build_path(), "docs.exs")
    File.write!(config, inspect(project()[:docs], limit: :infinity))

    args = [
      "Depdep",
      @version,
      Mix.Project.compile_path(),
      "--config",
      config,
      "--package",
      "depdep",
      "--source-url",
      @source_url,
      "--source-ref",
      "v#{@version}",
      # A docstring naming a function that does not exist, or is private, is
      # a dead link on hexdocs. Two shipped that way before docs were built
      # at all (#78); a warning that fails the build cannot.
      "--warnings-as-errors"
    ]

    case System.cmd(escript, args, into: IO.stream()) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("mix docs: ex_doc exited with status #{status}")
    end
  end

  defp description do
    "Content-addressed store for build artifacts: compiled Elixir dependencies, " <>
      "distribution packages and git mirrors."
  end
end
