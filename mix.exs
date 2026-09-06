defmodule Depdep.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  # `:inets` for `:httpc`, `:ssl` for an https endpoint, `:crypto` for SHA-256
  # and the HMAC chain of AWS Signature v4. `:erl_tar` is in `:stdlib`.
  def application do
    [extra_applications: [:inets, :ssl, :crypto]]
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

  defp description do
    "Content-addressed store for build artifacts: compiled Elixir dependencies, " <>
      "distribution packages and git mirrors."
  end
end
