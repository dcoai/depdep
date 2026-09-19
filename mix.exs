defmodule Depdep.MixProject do
  use Mix.Project

  # Moves in the same commit the release tag will point at. Nothing warns when a
  # tag and this disagree, and they did for two releases before being collapsed
  # back to one — see #40.
  @version "0.4.0"
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
      docs: [main: "readme", extras: ["README.md"]]
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

  defp description do
    "Content-addressed store for build artifacts: compiled Elixir dependencies, " <>
      "distribution packages and git mirrors."
  end
end
