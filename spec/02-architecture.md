# Architecture

Depdep is one executable, thirty modules, and no runtime dependencies. This file
is the map: what each group of modules is for, and where the behaviour it
implements is specified.

The shape of a run is the same whatever it moves. A provider says what the units
are and how to put one on disk; everything between — keying, transferring,
bucketing, reporting, measuring — is indifferent to which kind of artifact it is
handling. That indifference is the architecture's one real idea, and every module
below is on one side of it or the other.

## The command line {#cli}

`Depdep.CLI` parses, validates and dispatches, and owns all IO. Nothing else
prints. `Depdep.CLI.Operator` holds the two operator modes, `--report` and
`--sweep`, which are separated because they need a credential a pipeline should
not have.

Specified in `spec/09-cli.md`; reclamation's rules in
`spec/08-reclamation.md`.

## Asking Mix {#asking-mix}

`Depdep.Deps` is **the one place Mix is asked** about a project's dependencies,
and `Depdep.Member` is the one place any question about a member is asked — both
inside the member's own project. `Depdep.Lock` reads `mix.lock`.
`Depdep.Layout` decides which projects a run covers. `Depdep.BuildPath` answers
where one builds.

Depdep used to re-derive what these now ask for, and every defect that produced
was an edge of a rule Mix already owns. Specified in
`spec/06-the-run.md#member`, `spec/04-store-layout.md#layout`.

## The key {#key}

`Depdep.Key` computes it, `Depdep.Config` supplies the compile-time
configuration slice, and `Depdep.Json` is the canonical encoder the digests rest
on. Specified in `spec/03-keys.md`.

## Providers {#providers}

`Depdep.Provider` is the behaviour; `Depdep.Provider.Mix`,
`Depdep.Provider.Apt` and `Depdep.Provider.Git` implement it, with
`Depdep.Provider.Mix.Get` handling `--mix-get`. `Depdep.Unit` is what they hand
back and `Depdep.Archive` is how a unit becomes bytes.

Specified in `spec/05-units-and-providers.md`.

## The store {#store}

`Depdep.S3` is the entire network surface: Signature v4, the six calls depdep
makes, and the concurrency derivation. Specified in
`spec/04-store-layout.md#s3`.

## The run's shape {#run}

`Depdep.SecondPass` decides what the second enumeration changes,
`Depdep.RestoreCheck` asks Mix whether it accepts what was restored, and
`Depdep.Compile` with `Depdep.Compile.Log` compiles the misses and times them.
`Depdep.Roots` records what a consumer still needs.

Specified in `spec/06-the-run.md`.

## Measurement {#measurement}

`Depdep.Metrics` is the run's numbers, `Depdep.Report` is the summary a human
reads, `Depdep.Metresis` posts them, and `Depdep.Profile` with
`Mix.Tasks.Depdep.Profile` keeps the vocabulary honest. `Depdep.Sweep` is the
pure half of reclamation.

Specified in `spec/07-metrics-and-profile.md` and `spec/08-reclamation.md`.

## Why the pure parts are pure {#purity}

`Depdep.Sweep`, `Depdep.SecondPass`, `Depdep.Key` and `Depdep.Report` take their
inputs as arguments and touch nothing. The rules worth being certain about are
therefore testable without a store, a network or a clock.

The split has a cost, and it is recorded rather than hidden: a decision that
stays in the impure half can end up untested. That is what happened to
reclamation's most important rail — the refusal to sweep a store with no current
roots sat in `Depdep.CLI.Operator`, which talks to a store, while every other
sweep rule sat in the pure module and was tested. It had no test at all (#126).

The answer taken was to move the decision into the pure half
(`Depdep.Sweep.current_roots/2`), not to abandon the split. A rule that decides
whether to delete belongs beside the rules that decide what to delete.

## What is deliberately not described here {#not-described}

Some public functions carry no behaviour a reader of this specification needs:
accessors that exist so a test can reach a constant, and formatting helpers whose
output is asserted by the tests that use them.

**One item is excused: `Depdep.CLI.main/1`.** It calls `System.halt/1`, so no test
can call it and then assert — a claim cited against it could only ever be
asserted, never shown. The decisions it wires are each public and tested for that
reason, and they are cited where they are specified —
`spec/01-goals-and-scope.md#failure-not-error` and `spec/09-cli.md#parsing`,
`#combinations` and `#hints` — not here. This file names no code, for the reason
#138 gives.

#120 reported that nothing needed excusing. That was true only because the wrapper
had been **cited** where it should have been excused; #137 corrected it, and
`classes`/`rules` found their first genuine use.

The excusal is **by class**, never item by item: the rule matches `main/N`, so
another entry point added later falls into the class quietly while a new decision
matches no rule and is a gap. A class is for code whose only story is that it wires
things together, and a halting wrapper is exactly that.
