defmodule Depdep.RestoreCheckStatusesTest do
  @moduledoc """
  `statuses/2` asked **in process** (#139).

  This is depdep's converge — it asks Mix whether it would keep what a restore put
  on disk — and until now it was exercised only through
  `cli_rebuilt_integration_test.exs`, which shells out so the real binary runs.
  That test is the right one for proving the shipped behaviour, and it is the wrong
  one for this: a subprocess call is invisible, so nothing could show which code it
  reaches, and the relation could never be validated.

  It was also depdep's least-tested seam. #126 was the same lesson in the same
  module — a decision on the impure side goes untested — and this is the other half
  of it.

  `async: false`: `Depdep.Member.ask/3` wraps `Mix.Project.in_project/4`, which
  moves the VM's working directory and pushes Mix's project stack for the duration.
  A test running beside this one that assumes the current directory fails in a way
  that looks unrelated.
  """
  use ExUnit.Case, async: false

  alias Depdep.{RestoreCheck, Unit}

  setup do
    base = Path.join(System.tmp_dir!(), "statuses-#{System.unique_integer([:positive])}")
    app = Path.join(base, "app")
    File.mkdir_p!(Path.join(app, "config"))
    on_exit(fn -> File.rm_rf!(base) end)

    File.write!(Path.join(app, "mix.exs"), """
    defmodule StatusesFixture#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :statuses_fixture, version: "0.1.0", deps: deps()]
      defp deps, do: [{:jason, "~> 1.4"}]
    end
    """)

    File.write!(Path.join([app, "config", "config.exs"]), "import Config\n")

    File.write!(Path.join(app, "mix.lock"), """
    %{
      "jason": {:hex, :jason, "1.4.4", "innerjason", [:mix], [], "hexpm", "outerjason"}
    }
    """)

    %{app: app}
  end

  defp unit(name, dir),
    do: %Unit{
      name: name,
      group: nil,
      resolution: {:key, "deadbeef"},
      context: %{project_dir: dir}
    }

  @tag verifies: "statuses-asks-mix-once-per-member"
  test "a dependency Mix will not accept is a rebuild, with Mix's reason and the evidence",
       ctx do
    # `jason` is in the lock and not on disk, so Mix refuses it. Which refusal it
    # is belongs to Mix; `statuses/2`'s contract is that anything other than
    # `{:ok, _}` is a rebuild, named with Mix's own sentence.
    verdicts = RestoreCheck.statuses([unit("jason", ctx.app)], :test)

    assert {:rebuild, reason, evidence} = verdicts["jason"]
    assert is_binary(reason) and reason != ""

    # The evidence is what `--explain-rebuilt` prints (#135): where Mix looks for
    # the manifest, and the three values it compares against.
    assert %{build: build, expected: {{elixir, otp}, _scm, _lock}} = evidence
    assert is_binary(to_string(build))
    assert elixir == System.version()
    assert otp == :erlang.system_info(:otp_release)
  end

  test "a unit Mix does not list at all is absent from the map, not guessed at", ctx do
    verdicts = RestoreCheck.statuses([unit("not_a_dependency", ctx.app)], :test)

    refute Map.has_key?(verdicts, "not_a_dependency")
  end

  test "units are grouped by project, so one converge answers for all of a member's", ctx do
    units = [unit("jason", ctx.app), unit("not_a_dependency", ctx.app)]

    verdicts = RestoreCheck.statuses(units, :test)

    assert Map.keys(verdicts) == ["jason"]
  end
end
