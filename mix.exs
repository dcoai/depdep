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
      deps: deps(),
      name: "Dependency Depot",
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

  # DELIBERATELY EMPTY, AND IT HAS TO STAY THAT WAY.
  #
  # Depdep runs BEFORE `mix deps.get` — that is the whole point of it. A
  # dependency here would have to be fetched by the machinery this exists to
  # get in front of. Signature v4 is about sixty lines; `:httpc` and `:erl_tar`
  # ship with OTP. See README, "Why no dependencies".
  defp deps, do: []

  defp description do
    "Content-addressed store for compiled Elixir dependencies, keyed by a " <>
      "recursive Merkle hash over each dependency's input closure."
  end
end
