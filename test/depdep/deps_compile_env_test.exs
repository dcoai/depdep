defmodule Depdep.DepsCompileEnvTest do
  @moduledoc """
  `Depdep.Deps.converged/3` with `compile_env: true`: the member's compile-time config is
  in the application env while Mix decides each dependency's status, and gone afterwards.

  This is the guard that was missing (#161, for #141). Mix's `compile_env_status/2` calls
  `Config.Provider.valid_compile_env?/1`, which compares a dependency's recorded value
  against `Application.fetch_env` **in this VM**. With the member's config absent, every
  dependency recording a value the consumer sets to a non-default was `:envoutdated` — a
  correct restore refused, and refused again every run, because the stored object was
  never wrong. Nothing here asserted the application env at all, which is why it shipped.
  """
  use ExUnit.Case, async: false

  alias Depdep.Deps

  @app :depdep_compile_env_fixture
  @key :set_by_the_member

  setup do
    dir = Path.join(System.tmp_dir!(), "depdep-cenv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "config"))
    on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(fn -> Application.delete_env(@app, @key, persistent: true) end)
    on_exit(fn -> Application.delete_env(:depdep_probe_witness, :seen, persistent: true) end)
    Application.delete_env(:depdep_probe_witness, :seen, persistent: true)

    # A path dependency whose mix.exs is loaded BY the converge, so it runs inside the
    # window where the member's config is supposed to be in the application env. It
    # records what it saw into an application key of its own, which is the only way to
    # observe that window from outside the converge.
    probe = Path.join(dir, "probe")
    File.mkdir_p!(probe)

    File.write!(Path.join(probe, "mix.exs"), """
    defmodule Probe#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project

      def project do
        Application.put_env(:depdep_probe_witness, :seen, Application.get_env(#{inspect(@app)}, #{inspect(@key)}), persistent: true)
        [app: :probe, version: "0.1.0"]
      end
    end
    """)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CEnv#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :cenv_fixture, version: "0.1.0", deps: [{:probe, path: "probe"}]]
    end
    """)

    File.write!(Path.join([dir, "config", "config.exs"]), """
    import Config
    config #{inspect(@app)}, set_by_the_member: :from_the_member
    """)

    %{dir: dir}
  end

  @tag verifies: "restore-check-asks-with-the-members-config"
  test "the member's config is in the application env during the converge", ctx do
    refute Application.get_env(@app, @key),
           "the fixture's value must not be set before the converge, or this proves nothing"

    _ = Deps.converged(ctx.dir, :test, compile_env: true)

    assert Application.get_env(:depdep_probe_witness, :seen) == :from_the_member,
           "Mix loaded a dependency's project without the member's config in the " <>
             "application env, which is exactly how a correct restore came to be refused"
  end

  test "and is gone afterwards, so depdep's own VM is not left holding it", ctx do
    _ = Deps.converged(ctx.dir, :test, compile_env: true)

    refute Application.get_env(@app, @key),
           "a consumer's config outlived the question depdep asked with it"
  end

  test "a value already set is restored, not clobbered", ctx do
    Application.put_env(@app, @key, :was_here_first, persistent: true)

    _ = Deps.converged(ctx.dir, :test, compile_env: true)

    assert Application.get_env(@app, @key) == :was_here_first
  end

  # The key path must not acquire the member's config: it does not need it, and
  # Depdep.Config.digest_for/2 reads the config it is handed rather than this.
  test "without the option, nothing is loaded", ctx do
    _ = Deps.converged(ctx.dir, :test)

    refute Application.get_env(@app, @key)

    refute Application.get_env(:depdep_probe_witness, :seen),
           "the key path saw the member's config"
  end
end
