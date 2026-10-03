defmodule Depdep.CLI do
  @moduledoc """
  The command line: `--plan`, `--pull`, `--push`.

  Invoked from a consumer's bootstrap script, which is how depdep runs before
  `mix deps.get` without being a dependency of the project it is serving:

      Mix.install([{:depdep, git: "...", tag: "v0.2.0"}])
      Depdep.CLI.main(System.argv())

  **Nothing below names an artifact type.** What is being moved, how it is keyed
  and where it belongs on disk are all `Depdep.Provider`'s business; this module
  owns the store, the concurrency, the counting and the rule that no failure
  here may fail a build.
  """

  alias Depdep.{Metresis, Metrics, Provider, Report, Roots, Unit}

  @switches [
    plan: :boolean,
    report: :boolean,
    sweep: :boolean,
    confirm: :boolean,
    within: :integer,
    grace: :integer,
    keep_epochs: :integer,
    consumer: :string,
    ref: :string,
    pull: :boolean,
    push: :boolean,
    mix_get: :boolean,
    compile_deps: :boolean,
    explain_rebuilt: :boolean,
    provider: :keep,
    project: :keep,
    exclude: :keep,
    env: :string,
    package: :keep,
    apt_cache_dir: :string,
    repo: :keep,
    git_mirror_dir: :string,
    metrics: :string,
    help: :boolean
  ]

  @doc """
  The switches this version accepts, as `OptionParser` strict options.

  Public so `spec/09-cli.md#switches` can be held to it in both directions
  (#119): a switch accepted and undocumented is invisible to a reader, and a
  switch documented and not accepted is a promise the code does not keep.
  """
  def switches, do: @switches

  def main(argv) do
    with {:ok, opts} <- classify(parse(argv), :switch),
         :run <- disposition(opts),
         {:ok, providers} <-
           classify(Provider.resolve(Keyword.get_values(opts, :provider)), :switch),
         :ok <- classify(combination(opts, providers), :switch) do
      run(providers, opts)
    else
      :help ->
        IO.puts(usage())

      {:disabled, value} ->
        # Not a warning: nothing went wrong, and this line IS the run's summary,
        # so it belongs where the summary goes.
        IO.puts("depdep: disabled by DEPDEP_ENABLED=#{value}")

      {:error, class, problems} ->
        problems |> List.wrap() |> Enum.each(&warn/1)
        warn(hint(class))
        System.halt(2)
    end
  end

  @doc """
  Whether the switches make sense together: `:ok`, or `{:error, message}`.

  `--mix-get` runs `mix deps.get` between a pull's two passes, so it means
  nothing without `--pull`, and nothing for a provider that has no `deps.get`.
  Refused for the reason `parse/1` refuses an unknown switch: someone edited
  the invocation, and silently doing less than they asked is how an afternoon
  gets lost. Pure, so the message is testable without halting.
  """
  def combination(opts, providers) do
    cond do
      opts[:compile_deps] == true and opts[:mix_get] != true ->
        {:error,
         "--compile-deps compiles what a pull left missing after --mix-get, so it needs both"}

      opts[:explain_rebuilt] == true and opts[:pull] != true ->
        {:error,
         "--explain-rebuilt explains what a pull restored and Mix refused, so it needs --pull"}

      opts[:mix_get] != true ->
        :ok

      opts[:pull] != true ->
        {:error, "--mix-get runs mix deps.get inside a pull, so it needs --pull"}

      providers != [Depdep.Provider.Mix] ->
        {:error, "--mix-get is for the mix provider only"}

      true ->
        :ok
    end
  end

  # Every error that reaches `main/1` says which kind of thing was wrong, so the
  # hint can follow the error rather than the branch. The producers keep their
  # `{:error, _}` shape — `enabled?/0` and `parse/1` are tested on it — and the
  # class is attached where `main/1` consumes them.
  defp classify({:error, problems}, class), do: {:error, class, problems}
  defp classify(other, _class), do: other

  @doc """
  The one-line hint printed after a usage error, chosen by what went wrong.

  There used to be a single sentence for the whole branch, written when every
  error in it was a switch error. #50 then routed `DEPDEP_ENABLED` through the
  same branch and the sentence was reused unread, so a reader whose
  *environment variable* was refused was told the problem was a switch (#54).
  `--help` documents both, which is why each hint can still point there.

  Pure and public for the reason `parse/1` is: `main/1` halts, so a decision
  worth testing must be observable without ending the VM. A third error class
  added later has to choose its sentence here rather than inherit one.
  """
  def hint(:switch), do: "run with --help for the switches this version understands"
  def hint(:environment), do: "run with --help for the environment variables this version reads"

  # Help first, and before `enabled?/0`: `--help` is a request to read the
  # documentation, so answering it with an exit code — because the environment
  # holds a typo — is unhelpful at exactly the moment help was asked for.
  @doc """
  What the invocation asks for before anything is read: `:run`, `:help`,
  `{:disabled, value}` or `{:error, class, message}`.

  **Public for the reason `parse/1` is** (#137): `main/1` halts, so a decision worth
  testing must be observable without ending the VM. This one was private by
  oversight — `spec/01-goals-and-scope.md#failure-not-error` cited `main/1` for the
  exit behaviour, which no test can call and then assert, so the claim could never
  be shown. It cites this instead.
  """
  def disposition(opts) do
    if opts[:help] do
      :help
    else
      case enabled?() do
        {:ok, true} -> concurrency_disposition()
        {:ok, false} -> {:disabled, System.get_env("DEPDEP_ENABLED")}
        {:error, message} -> {:error, :environment, message}
      end
    end
  end

  # After `enabled?/0` rather than beside it, deliberately: a disabled run reads
  # nothing else, so a typo in DEPDEP_CONCURRENCY must not stop the one
  # invocation whose entire purpose is to do nothing and exit 0.
  #
  # Read here, before any provider runs, for the reason `parse/1` refuses an
  # unknown switch: the variable exists to make a number trustworthy, so a value
  # it cannot read is a usage error, and discovering it halfway through a
  # transfer would leave the run half-measured.
  defp concurrency_disposition do
    case Depdep.S3.concurrency_setting() do
      {:ok, _} -> :run
      {:error, message} -> {:error, :environment, message}
    end
  end

  @doc """
  Whether depdep should do anything at all: `{:ok, boolean}`, or `{:error,
  message}` for a value it cannot read.

  **Unset means enabled**, so every consumer that ignores this variable is
  unaffected, and an empty value means unset — a CI variable declared without
  one is ordinary, and `Depdep.S3` already reads `""` that way.

  `DEPDEP_ENABLED=false` exists because turning the store off used to mean
  unsetting `DEPDEP_ENDPOINT`: editing the store's configuration to take a
  measurement, and remembering to put it back. Two cases want it. The first is
  the cold half of a before/after — the comparison #41 is open about, where a
  baseline that was quietly served from the store is worse than no baseline. The
  second is a pipeline where depdep is the suspect, which is why the check runs
  before providers, credentials, `mix.lock` or `config/config.exs`: an off
  switch that needs depdep to work is no use on the day depdep does not.

  **An unreadable value fails.** This is the argument `parse/1` makes about an
  unknown switch, and it is sharper here: the whole point of the switch is a
  number someone will trust, so `DEPDEP_ENABLED=flase` quietly meaning "enabled"
  would hand back a warm restore labelled as a cold build. Unlike a switch, this
  can be inherited from a CI group, so a typo can stop more than the pipeline
  being edited — a loud one-line fix, chosen over a silent wrong answer.
  """
  def enabled? do
    case System.get_env("DEPDEP_ENABLED") do
      nil -> {:ok, true}
      value -> from_value(String.downcase(String.trim(value)))
    end
  end

  defp from_value(""), do: {:ok, true}
  defp from_value("true"), do: {:ok, true}
  defp from_value("false"), do: {:ok, false}

  defp from_value(other),
    do: {:error, ~s(DEPDEP_ENABLED is "#{other}"; it takes "true" or "false")}

  @doc """
  `{:ok, opts}`, or `{:error, messages}` for anything not understood.

  Separate from `main/1` because `main/1` halts, and a decision worth testing
  should not require ending the VM to observe.

  **A switch depdep does not understand is a usage error, and usage errors
  fail.** That is not a hole in "failure is not an error" — that promise is about
  reaching and using the STORE, where the worst case is that the tool does the
  work itself. Nothing has failed to be reached here; depdep has been asked for
  something it cannot do. Silently dropping it is how `dco-tek/metresis` #86 lost
  an afternoon: `--provider apt` against a tag that predated providers went into
  `invalid`, the mix provider ran instead, and it died evaluating
  `config/config.exs` — which reads as a config bug.

  What makes failing safe here is that **an unknown switch cannot arrive on its
  own.** Someone has to edit the invocation, so this can never break a pipeline
  that was working; it can only stop one that has just been changed, which is
  when being stopped is useful.
  """
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _rest, []} ->
        {:ok,
         Keyword.merge(opts,
           root: File.cwd!(),
           env: String.to_atom(opts[:env] || "test")
         )}

      {_opts, _rest, invalid} ->
        {:error, Enum.map(invalid, &problem/1)}
    end
  end

  # `OptionParser` reports an unknown switch and a badly-typed value the same
  # way — `{"--thing", nil}` — so the name has to be checked against the known
  # set. Saying which it is matters: a reader whose value is missing should not
  # go looking for a typo.
  defp problem({switch, _value}) do
    if switch in known_switches() do
      "#{switch} was given a value it cannot take"
    else
      "#{switch} is not a switch this version of depdep understands"
    end
  end

  defp known_switches,
    do: Enum.map(@switches, fn {name, _} -> "--" <> String.replace("#{name}", "_", "-") end)

  defp run(providers, opts) do
    cond do
      opts[:plan] -> plan(providers, opts)
      opts[:report] -> Depdep.CLI.Operator.report(opts)
      opts[:sweep] -> Depdep.CLI.Operator.sweep(opts)
      opts[:pull] -> transfer(providers, opts, :pull)
      opts[:push] -> transfer(providers, opts, :push)
      true -> IO.puts(usage())
    end
  end

  defp plan(providers, opts) do
    # A plan shows what a pull would do; there is no third direction.
    opts = Keyword.put(opts, :direction, :pull)

    Enum.each(providers, fn provider ->
      {:ok, units, warnings} = provider.enumerate(opts)
      Enum.each(warnings, &warn/1)

      Enum.each(units, fn unit ->
        IO.puts([columns(unit), "\t", plan_key(unit.resolution)])
      end)
    end)
  end

  defp columns(%Unit{group: nil} = unit), do: [unit.name, "\t", unit.detail]
  defp columns(unit), do: [unit.group, "\t", unit.name, "\t", unit.detail]

  defp plan_key({:key, hash}), do: hash
  defp plan_key({:skip, reason}), do: "SKIP #{reason}"
  defp plan_key({:not_for_env, env}), do: "NOT FOR ENV #{env}"

  # The store is a cache. Every path out of this function that is not a hit ends
  # in "the tool does the work itself", which is why none of them are errors.
  defp transfer(providers, opts, direction) do
    case Depdep.S3.config() do
      {:error, reason} ->
        warn("store not configured (#{reason}) — skipping #{direction}, nothing will break")

        # The line this switch replaces ran `mix deps.get` whether or not a
        # store existed, so an unconfigured store must not be how a fetch is
        # silently skipped.
        if opts[:mix_get] do
          {_phases, _units, status} = mix_get([], opts, nil)
          if status != 0, do: System.halt(status)

          # With no store, nothing was restored, so every dependency is what a
          # pull would have left missing: the consumer's compile moved one line
          # up, still timed, still Mix's exit status.
          if opts[:compile_deps], do: compile_without_store(opts)
        end

        :ok

      {:ok, cfg} ->
        Depdep.S3.start()

        # `:direction` because what a provider wants moved can differ by
        # direction: `Depdep.Provider.Apt` asks apt what it WILL fetch on a pull
        # and asks the archives directory what WAS fetched on a push, and those
        # are genuinely different questions.
        opts = Keyword.put(opts, :direction, direction)

        # The clock starts where depdep starts working. `Mix.install` cloning
        # and compiling depdep is the consumer's cost and varies with their
        # runner's cache — folding it in would put back exactly the noise this
        # number exists to remove.
        {elapsed, {phases, mix_units, exit_status}} =
          :timer.tc(fn ->
            phases = Enum.map(providers, &transfer_provider(&1, opts, direction, cfg))
            if opts[:mix_get], do: mix_get(phases, opts, cfg), else: {phases, [], 0}
          end)

        # Outside the transfer's clock: `elapsed` is what depdep cost, and a
        # compile is what the store did NOT save this time.
        {phases, compiled, exit_status} =
          if opts[:compile_deps] == true and exit_status == 0,
            do: compile_deps(phases, mix_units, opts),
            else: {phases, nil, exit_status}

        # The summary line is unchanged, deliberately: the tallies it renders are
        # now carried on the phases rather than returned instead of them.
        IO.puts(
          "depdep: " <>
            Report.render(direction, Report.merge(Enum.map(phases, & &1.tally))) <>
            " in " <>
            Report.duration(elapsed) <>
            compiled_clause(compiled) <> saved_clause(phases) <> rebuilt_clause(phases)
        )

        write_metrics(opts, phases, direction, elapsed)
        post_metrics(phases, direction, elapsed)

        # After the summary and the metrics, never before: what the pull did is
        # still true and still worth recording when the fetch or the compile
        # that followed it failed. The status is Mix's own — the job fails here
        # exactly as it would have on the line this replaces (#60, #59).
        if exit_status != 0, do: System.halt(exit_status)
    end
  end

  defp compile_without_store(opts) do
    {:ok, units, warnings} = Depdep.Provider.Mix.enumerate(opts)
    Enum.each(warnings, &warn/1)
    env = Keyword.fetch!(opts, :env)

    absent =
      Depdep.Compile.select(units, fn unit ->
        not match?({:not_for_env, _}, unit.resolution) and
          not Depdep.Provider.Mix.present?(unit)
      end)

    {us, {status, measured, _unmeasured}} =
      :timer.tc(fn -> Depdep.Compile.run(absent, env) end)

    IO.puts("depdep: compiled #{map_size(measured)} in " <> Report.duration(us))
    if status != 0, do: System.halt(status)
  end

  # Only when something knows. `saved ~0s` from a store that has never carried
  # a compile time would read as "the store is useless", which is not what it
  # would mean.
  defp saved_clause(phases) do
    case Metrics.saved_total_us(phases) do
      nil -> ""
      us -> " — saved ~" <> Report.duration(us)
    end
  end

  # Only when it happened: a restore Mix would not keep is the key's failure,
  # and a line that says `rebuilt 0` every day would teach readers to skip it.
  defp rebuilt_clause(phases) do
    case Depdep.RestoreCheck.count(phases) do
      0 -> ""
      n -> " — rebuilt #{n}"
    end
  end

  defp compiled_clause(nil), do: ""
  defp compiled_clause({n, us}), do: " — compiled #{n} in " <> Report.duration(us)

  # Exactly the misses, named to one `mix deps.compile` per member. Mix orders
  # them; depdep times them from the boundaries Mix prints. A restored unit is
  # never mentioned, so Mix never looks at it (#59). Every miss is one Mix's
  # own list says this env builds (`Depdep.Deps`), so none is refused.
  defp compile_deps(phases, mix_units, opts) do
    {mix_phases, others} = Enum.split_with(phases, &(&1.provider == "mix"))
    env = Keyword.fetch!(opts, :env)

    missing =
      for phase <- mix_phases,
          %Metrics.Unit{bucket: :missing, label: label} <- phase.units,
          do: label

    to_compile = Depdep.Compile.select(mix_units, missing)

    {us, {status, measured, unmeasured}} =
      :timer.tc(fn -> Depdep.Compile.run(to_compile, env) end)

    Enum.each(unmeasured, fn label ->
      warn("#{label}: compiled, but Mix printed no boundary for it — no compile time recorded")
    end)

    if status != 0, do: warn("mix deps.compile exited #{status} — the run ends with that status")

    phases =
      Enum.map(mix_phases, fn phase ->
        %{phase | units: Enum.map(phase.units, &with_compile(&1, measured))}
      end) ++ others

    {phases, {map_size(measured), us}, status}
  end

  defp with_compile(%Metrics.Unit{label: label} = unit, measured) do
    case Map.fetch(measured, label) do
      {:ok, {us, kind}} -> %{unit | compile_us: us, compile_exact: kind == :exact}
      :error -> unit
    end
  end

  # Own the middle line so the third can go: run `deps.get`, then decide again
  # what the first pass could not. `Depdep.SecondPass` says which units that
  # is; only those are transferred, and only the mix phase changes.
  defp mix_get(phases, opts, cfg) do
    root = Keyword.fetch!(opts, :root)
    {projects, _notes} = Depdep.Layout.projects(root, opts)

    case Depdep.Provider.Mix.Get.run(root, projects, Keyword.fetch!(opts, :env)) do
      :ok ->
        {phases, units} = Enum.map_reduce(phases, [], &second_pass(&1, &2, opts, cfg))
        {phases, units, 0}

      {:error, {project, status}} ->
        warn("mix deps.get failed in #{project} (exit #{status}) — the second pass is not run")
        {phases, [], status}
    end
  end

  # Returns the phase as the run ended and the re-enumerated mix units, which
  # `--compile-deps` needs to know where each miss lives.
  defp second_pass(%Metrics.Phase{provider: "mix"} = phase, _units, opts, cfg) do
    provider = Depdep.Provider.Mix
    {:ok, units, warnings} = provider.enumerate(opts)
    Enum.each(warnings, &warn/1)

    # The root is written again with the fuller list: a git dependency keyed
    # only now is as needed as the rest, and the sweep must not miss it.
    record_root(provider, units, opts, cfg)

    {transfer, settled} = Depdep.SecondPass.plan(phase.units, units)
    {span, {_tally, transferred}} = transfer_units(provider, transfer, :pull, cfg)
    phase = Depdep.SecondPass.merge(phase, settled, transferred, span)

    # Then ask Mix whether it would keep what was restored (#85). A unit it
    # would rebuild is a miss after all, named with Mix's reason, and
    # --compile-deps then compiles it like any other miss.
    env = Keyword.fetch!(opts, :env)
    # Once, not once per use: `statuses/2` converges per member, and
    # `spec/06-the-run.md#two-converges` is explicit that there are two converges
    # in a run on purpose. A third for the sake of a diagnostic would be a
    # performance regression hidden behind a flag.
    verdicts = Depdep.RestoreCheck.statuses(units, env)
    {phase, rebuilt} = Depdep.RestoreCheck.apply(phase, verdicts)

    Enum.each(rebuilt, fn {label, reason} ->
      warn("#{label}: restored, but Mix would rebuild it — #{reason} — counted as a miss")

      if opts[:explain_rebuilt] == true do
        case Map.get(verdicts, label) do
          {:rebuild, _why, evidence} ->
            Enum.each(Depdep.RestoreCheck.explain(evidence), &warn("  " <> &1))

          _ ->
            :ok
        end
      end
    end)

    {phase, units}
  end

  defp second_pass(phase, units, _opts, _cfg), do: {phase, units}

  defp transfer_provider(provider, opts, direction, cfg) do
    {:ok, units, warnings} = provider.enumerate(opts)
    Enum.each(warnings, &warn/1)
    if direction == :pull, do: record_root(provider, units, opts, cfg)

    concurrency = Depdep.S3.concurrency()
    {span, {tally, unit_metrics}} = transfer_units(provider, units, direction, cfg)

    %Metrics.Phase{
      provider: Depdep.Provider.name(provider),
      direction: direction,
      span_us: span,
      concurrency: concurrency,
      tally: tally,
      units: unit_metrics
    }
  end

  # One concurrent phase over `units`: `{span_us, {tally, unit_metrics}}`.
  defp transfer_units(provider, units, direction, cfg) do
    # `timeout: :infinity` is deliberate and is NOT "no timeout". `Depdep.S3`
    # gives `:httpc` a 15 s connect and 300 s request timeout, so a stuck
    # transfer comes back as `{:error, _}` — attributable to its unit, reported
    # with a reason, and counted in the right bucket. A timeout at the stream
    # level would surface as `{:exit, :timeout}` carrying no identity, and the
    # run could name neither the unit nor the cause. Enforce it where the
    # identity still exists.
    #
    # A crash inside a step still takes the run down, exactly as it did when
    # this was an `Enum.reduce`. That is not an oversight: a provider reading a
    # file depdep itself just wrote and failing is a broken machine, not a cold
    # cache.
    concurrency = Depdep.S3.concurrency()

    # Read once, before the stream, so every unit's offset is measured from the
    # same origin. Queue wait is the difference between this and a unit's entry,
    # and it is the only way to tell a phase that was concurrency-bound from one
    # that simply had little to do.
    phase_start = System.monotonic_time(:microsecond)

    :timer.tc(fn ->
      units
      |> Task.async_stream(&step(provider, &1, direction, cfg, phase_start),
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({%{}, []}, fn {:ok, {bucket, metrics}}, {tally, acc} ->
        {Report.count(tally, direction, bucket), [metrics | acc]}
      end)
    end)
  end

  # Never fails the run. A measurement that could break a pipeline would be a
  # worse instrument than no measurement, and `--metrics` is a debugging
  # convenience rather than the record.
  defp write_metrics(opts, phases, direction, elapsed) do
    case opts[:metrics] do
      nil ->
        :ok

      path ->
        case Metrics.write(path, Metrics.to_map(phases, direction, elapsed)) do
          :ok -> :ok
          {:error, message} -> warn("could not write metrics — #{message}")
        end
    end
  end

  # `Depdep.Report.outcome/3` decides everything that can be decided without the
  # network, and only `:fetch` and `:offer` reach the store at all.
  #
  # Returns the bucket this unit lands in rather than a tally: results are folded
  # as they arrive from the stream, so a step must not carry one.
  defp step(provider, unit, direction, cfg, phase_start) do
    # Taken at entry rather than at scheduling: `Task.async_stream` starts at
    # most `max_concurrency` tasks at once, so the gap between the phase start
    # and this is the queue wait.
    base = %Metrics.Unit{
      provider: Depdep.Provider.name(provider),
      label: Unit.label(unit),
      offset_us: System.monotonic_time(:microsecond) - phase_start
    }

    case Report.outcome(direction, unit.resolution, provider.present?(unit)) do
      {:done, :skipped} ->
        {:skip, reason} = unit.resolution
        warn("#{Unit.label(unit)}: skipped — #{reason}")
        {:skipped, %{base | bucket: :skipped, reason: reason}}

      # A unit already on disk saved its whole compile, if it knows how long
      # that was: the note a --compile-deps or an earlier pull left beside it.
      {:done, :present} ->
        carried = known_compile(unit)
        saved = Depdep.Compile.saved_us(carried, 0)
        {:present, %{base | bucket: :present, saved_us: saved, compile_carried_us: carried}}

      {:done, bucket} ->
        {bucket, %{base | bucket: bucket}}

      {:network, action} ->
        reach(action, provider, unit, cfg, base)
    end
  end

  defp reach(:fetch, provider, unit, cfg, base) do
    tmp = tmp_path()

    {download_us, fetched} = :timer.tc(fn -> Depdep.S3.get(cfg, unit.object, tmp) end)

    # The size is read here because `File.rm/1` below is the last moment it
    # exists, and it is the compressed size — what actually crossed the network,
    # which is the number the download time belongs with.
    {restore_us, result, bytes} =
      case fetched do
        :ok ->
          size = size_of(tmp)
          {us, restored} = :timer.tc(fn -> provider.restore(unit, tmp) end)
          {us, restored, size}

        other ->
          {0, other, 0}
      end

    File.rm(tmp)

    measured = %{base | download_us: download_us, restore_us: restore_us, bytes: bytes}

    case result do
      :ok ->
        record(provider, unit)
        compile_us = carried_compile(cfg, unit)
        saved = Depdep.Compile.saved_us(compile_us, download_us + restore_us)

        {:pulled, %{measured | bucket: :pulled, saved_us: saved, compile_carried_us: compile_us}}

      {:error, "not found"} ->
        {:missing, %{measured | bucket: :missing, reason: "not found"}}

      {:error, reason} ->
        warn("#{Unit.label(unit)}: pull failed (#{reason}) — it will be built as usual")
        {:missing, %{measured | bucket: :missing, reason: reason}}
    end
  end

  defp reach(:offer, provider, unit, cfg, base) do
    case Depdep.S3.head(cfg, unit.object) do
      # A hit is the steady state, and it is exactly when the local tree is known
      # to match the key — so it must be noted here too. Noting only uploads
      # would leave a warm tree unrecognised and re-pulled on the next run.
      :hit ->
        record(provider, unit)
        {:stored, %{base | bucket: :stored}}

      :miss ->
        upload(provider, unit, cfg, base)

      {:error, reason} ->
        warn("#{Unit.label(unit)}: HEAD failed (#{reason}) — not uploading")
        {:skipped, %{base | bucket: :skipped, reason: reason}}
    end
  end

  # What the object says it cost to compile, read with one HEAD and kept beside
  # the build so the next run needs no request. A store that cannot answer, or
  # an object stored before compile times were, is `nil` — never a guess.
  defp carried_compile(cfg, unit) do
    case Depdep.S3.metadata(cfg, unit.object) do
      {:ok, %{"compile-us" => value}} ->
        case Integer.parse(value) do
          {us, ""} ->
            Depdep.Compile.record(unit, us)
            us

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp known_compile(unit) do
    case Depdep.Compile.read(unit) do
      {:ok, us} -> us
      :none -> nil
    end
  end

  defp upload(provider, unit, cfg, base) do
    tmp = tmp_path()

    # `restore_us` on a push is the tar being BUILT rather than unpacked — the
    # same half of the same round trip, so it shares the field rather than
    # doubling the schema for a direction that never mixes with the other.
    {restore_us, collected} = :timer.tc(fn -> provider.collect(unit, tmp) end)

    # The compile time travels with the object, when this build measured it.
    metadata =
      case known_compile(unit) do
        nil -> %{}
        us -> %{"compile-us" => us}
      end

    {upload_us, result, bytes} =
      case collected do
        :ok ->
          size = size_of(tmp)
          {us, put} = :timer.tc(fn -> Depdep.S3.put(cfg, unit.object, tmp, metadata) end)
          {us, put, size}

        other ->
          {0, other, 0}
      end

    File.rm(tmp)

    measured = %{base | download_us: upload_us, restore_us: restore_us, bytes: bytes}

    case result do
      :ok ->
        record(provider, unit)
        {:uploaded, %{measured | bucket: :uploaded}}

      {:error, reason} ->
        warn("#{Unit.label(unit)}: upload failed (#{reason}) — the store simply stays cold")
        {:skipped, %{measured | bucket: :skipped, reason: reason}}
    end
  end

  # Never fails the run, and never delays it by more than `Depdep.Metresis`'s own
  # timeout. The measurement is a by-product of work that already succeeded, so
  # it is the least entitled thing in the tool to change an exit code.
  defp post_metrics(phases, direction, elapsed) do
    case Metresis.post(Metrics.to_map(phases, direction, elapsed), direction) do
      :ok -> :ok
      :disabled -> :ok
      {:warn, message} -> warn(message <> " — the run is unaffected")
      {:error, reason} -> warn("metrics not reported (#{reason}) — the run is unaffected")
    end
  end

  # A stat that fails is not worth failing a transfer over: the bytes are a
  # measurement, and the transfer already succeeded.
  defp size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  # Written before any transfer: the paths are known once units are enumerated,
  # and a transfer that then fails does not make them less wanted. See
  # `Depdep.Roots` for why this happens on pull rather than push.
  defp record_root(provider, units, opts, cfg) do
    {consumer, ref} = Roots.identity(opts, Keyword.fetch!(opts, :root))
    object = Roots.path(consumer, ref, Provider.name(provider))
    paths = units |> Enum.map(& &1.object) |> Enum.reject(&is_nil/1)

    tmp = tmp_path()
    File.write!(tmp, Roots.encode(paths))
    result = Depdep.S3.put(cfg, object, tmp)
    File.rm(tmp)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        warn(
          "could not record what #{consumer}/#{ref} needs (#{reason}) — " <>
            "reclamation may treat these objects as unreachable"
        )
    end
  end

  # Bookkeeping: a note that cannot be written is reported and otherwise ignored.
  # Losing one costs a redundant pull next run; failing the build over it would
  # cost far more.
  defp record(provider, unit) do
    case provider.record(unit) do
      :ok ->
        :ok

      {:error, reason} ->
        warn("#{Unit.label(unit)}: could not note the key (#{reason}) — it will be pulled again")
    end
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "depdep-#{:erlang.unique_integer([:positive])}.tar.gz")

  defp warn(message), do: IO.puts(:stderr, "depdep: #{message}")

  defp usage do
    """
    Depdep — a content-addressed store for build artifacts.

      --plan     computed keys, no network
      --report   what the store holds, and how much of it is still reachable
      --sweep    remove what no current root needs (operator only; dry run
                 unless --confirm is given)
      --pull     restore what the store has
      --push     upload what it does not
      --help     this text
      --mix-get  with --pull: run mix deps.get after the pull, then decide again
                 what could not be decided before the source was on disk — a git
                 dependency and its cone are pulled in the same invocation, so
                 no second pull is needed. mix deps.get's exit status becomes
                 depdep's; the store's failures stay warnings.
      --compile-deps  with --pull --mix-get: compile exactly the dependencies the
                 pull left missing, one mix deps.compile per member naming only
                 those, timed per dependency from the boundaries Mix prints. Your
                 own mix compile then finds every dependency up to date. A
                 dependency that does not compile ends the run with Mix's status.

      --explain-rebuilt  with --pull: for each restore Mix refused, print what the
                 build's manifest recorded against what Mix expected — the
                 Elixir/OTP pair, the SCM and the lock entry, naming the first
                 differing tuple element. Off by default; it is a diagnostic for
                 when "restored, but Mix would rebuild it" needs explaining.

      --provider NAME operate on this artifact kind (repeatable).
                      Default: mix. Known: #{Provider.known()}

    Options for the mix provider:

      --project DIR   operate on this project (repeatable). Default: the current
                      directory if it holds a mix.exs, otherwise every mix.exs
                      beneath it.
      --exclude PREFIX drop a member and everything beneath it (repeatable),
                      matched on whole path segments
      --env ENV       MIX_ENV to operate on (default test)

    Options for --report and --sweep:

      --within DAYS   treat a root written within this many days as current
                      (default 30)

    Options for --sweep:

      --confirm       actually delete. Without it nothing is removed.
      --grace DAYS    never remove anything created this recently (default 2),
                      so a push racing the listing is not swept
      --keep-epochs N git mirrors to keep per repository (default 2)

    Options for --pull, which records what this consumer needs:

      --consumer NAME who is pulling (default: $CI_PROJECT_PATH, else the
                      checkout qualified by host)
      --ref NAME      which branch (default: $CI_COMMIT_REF_SLUG)

    Options for the apt provider:

      --package NAME      a package the job will install (repeatable). Needed
                          for --pull; --push reads the archives directory.
      --apt-cache-dir DIR where apt keeps downloaded packages
                          (default /var/cache/apt/archives)

    Options for the git provider:

      --repo URL           a repository to mirror (repeatable)
      --git-mirror-dir DIR where mirrors are kept (default .depdep/git)
      --metrics PATH  write this run's timings to PATH as JSON

    Reads the store from DEPDEP_STORE=s3://ACCESS_KEY@host:port/bucket[?region=…]
    and DEPDEP_SECRET_KEY (s3 is a plain-http endpoint, s3+https is TLS; the
    secret is never in the URL) — or, separately, DEPDEP_ENDPOINT,
    DEPDEP_BUCKET, DEPDEP_ACCESS_KEY, DEPDEP_SECRET_KEY and optionally
    DEPDEP_REGION. Both forms at once is refused. With the store unset, --pull
    and --push report why and do nothing.

    DEPDEP_ENABLED=false turns depdep off: it reports that it is off and exits
    0 without reading anything. Unset means enabled, so leaving it alone is the
    same as never having heard of it.

    DEPDEP_METRESIS (or DEPDEP_METRESIS_URL) and DEPDEP_METRESIS_TOKEN, both
    set, post this run's timings to a metresis instance. With either unset
    nothing is sent and no connection is attempted. A metresis that refuses,
    fails or hangs is a warning and never a failed run.

    DEPDEP_CONCURRENCY sets how many transfers run at once, for taking a
    measurement rather than for tuning: =1 is the serial baseline. Unset means
    derived from the scheduler count, which is what every real run should use.
    """
  end
end
