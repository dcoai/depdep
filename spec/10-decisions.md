# Decisions

Why depdep is the way it is, one entry per decision, so that a future change
argues with a recorded reason rather than with a guess about one.

An entry here is a decision that would be expensive to reverse or easy to reverse
by accident. Ordinary design choices live with the thing they shape.

## Zero runtime dependencies {#zero-deps}

Depdep runs before `mix deps.get`, so a runtime dependency would have to be
fetched by the machinery depdep exists to get in front of. There is no ordering in
which one could work. Signature v4 is about sixty lines; `:httpc` and `:erl_tar`
ship with OTP.

Build-time dependencies are allowed and bounded: see
`spec/01-goals-and-scope.md#zero-runtime-deps`.

## An input hash, never an output hash {#input-hash}

Hashing compiled output — module names, beam counts, export sets — fails twice. It
is unsound, measured: `oban` has an identical module set across six consumers
while one of them gains five functions in `Mix.Tasks.Oban.Install`. And an output
hash can only be computed *after* compiling, which is the cost being avoided.

Output hashes address objects. Input hashes are keys.

## The key recurses {#recursion}

Reversing this is the single most expensive mistake available here, because the
failure is silent: a build that compiles clean, passes its tests and is wrong.
The argument is in `spec/03-keys.md#recursion`, and the measured instance —
`Ash.Type.File.Source` resolving to `Any` while 106 of 106 tests passed — is why
it is stated as a decision rather than an optimisation.

## The key's inputs are Mix's own {#mix-inputs}

Depdep used to parse the lock, shell out to `mix deps.tree` and walk the `only:`
rule by hand. Every recent defect was an edge of a rule Mix owns, got slightly
wrong.

Schema `v3` replaced all of it with one converge and the fields of `%Mix.Dep{}`.
The cost was a cold refill of every consumer's store, once, and it was worth
paying: the class of defect it removed was "depdep disagrees with Mix", which no
amount of care in depdep could close.

## Two converges, not one {#two-converges}

Folding them would ask Mix about a disk it has not seen yet
(`spec/06-the-run.md#two-converges`). The second converge looks expensive and is
the only way the restore check can mean anything.

## Failure is not an error {#failure-not-error}

The store is an optimisation over work that has already succeeded, so no failure
to reach or use it may change a run's exit code. The one exception —
`--compile-deps` surfacing the consumer's own failing compile — is not a hole,
and `spec/09-cli.md#exit-codes` is the complete list.

## No `try`/`catch`/`rescue` {#no-rescue}

Not used anywhere. Rescuing hides the bug that produced the exception, and the
bugs worth catching here are the ones that produce a wrong restore — which is
exactly the class that does not raise. Every failure depdep expects is a value:
`{:error, reason}`, `{:skip, reason}`, `:miss`.

## The rule modules are pure {#purity}

`Depdep.Key`, `Depdep.Sweep`, `Depdep.SecondPass` and `Depdep.Report` take their
inputs as arguments and touch nothing. The rules worth being certain about are
testable without a store, a network or a clock.

The cost is real and is recorded in `spec/02-architecture.md#purity`: a decision
left in the impure half can go untested, which is what happened to reclamation's
most important rail (#126). The answer is to move the decision, not to abandon the
split.

## Configuration is sliced per application {#config-slice}

A project-wide configuration digest would differ for every consumer, so no two
would ever share an object and the store would hold one object per consumer per
dependency — saving nothing. The slice is what makes objects shareable at all.

## A stale git mirror is not a wrong answer {#mirror-staleness}

This is why the git provider's key is a monthly epoch rather than a commit, and
why reclamation keeps the newest epochs instead of computing reachability. A
mirror is a seed the consumer's own fetch reconciles, so staleness costs a larger
delta and nothing else. The same key would be unsound for a compiled dependency,
which is the contrast worth keeping in view.

## apt objects are never reclaimed {#apt-never-reclaimed}

Small, near-static, shared by every consumer and image, and their reachable set
needs apt in the right container to compute. Little to reclaim, more to get wrong.

## Roots, not checkouts {#roots}

A live set gathered by an operator running `--plan` across every consumer cannot
see branches, and getting any consumer's invocation wrong *shortens* the live set,
which means over-deletion. A root is produced by the thing that knows the answer
at the moment it knows it.

## The profile is identified by hash, not version {#profile-hash}

A hash is what a machine can compare exactly, and the handshake needs exactly
that. The version is for a person deciding whether to adopt. That the version is
not currently bumped when the vocabulary changes is a defect, filed as #111, not a
decision.

## Concurrency is derived, not tuned {#concurrency}

`DEPDEP_CONCURRENCY` exists so a serial baseline can be measured against the same
commit and the same objects. It is an instrument. If a measurement shows the
derivation is wrong, the derivation changes —
`spec/04-store-layout.md#concurrency`.

## The spec is held to the code, and the gate is narrower than first proposed {#the-gate}

`spec/` is related to the code it describes, and CI fails on a relation nobody has
looked at. Two of the three gate settings proposal #112 planned are set:

- **`require: [code: [:implements]]`** — every public item is described by a
  section. No excusal classes were needed: the spec describes all of them, which
  was not a foregone conclusion when #112 planned for classes.
- **`require: [test_hint: [:verifies]]`** — every test hint is verified by a test.

**`triangle: :fail` is not set, and this is a correction to #112 rather than a
deferral.** Closing the triangle requires every section's verifying test to call
every function that section cites. `spec/04-store-layout.md#s3` cites twelve
functions; `spec/02-architecture.md` is a map whose sections describe module
groupings that no single test can meaningfully verify. Setting it would demand
either hollow tests or the dismantling of the architecture map — and hollow tests
are how a gate teaches people to confirm without reading, which is the failure
`guides/writing-specs.md` §2 exists to prevent.

The triangle is therefore **reported, not gated**. 110 gaps are visible in every
`mix surfex.status`, and closing one where it is genuinely closeable is ordinary
work.

## What extraction found {#what-extraction-found}

Recorded because it is the evidence for whether writing this was worth it. Six
defects, none of which existing tests were going to surface:

| Issue | Found while writing | What it was |
|---|---|---|
| #121 | `01-goals-and-scope` | `Metresis.post/3`'s docstring omits an outcome it returns |
| #124 | #113's own pipeline | jobs overriding `before_script` stopped fetching deps; green once on a runner-local cache |
| #125 | `08-reclamation` | `--report` groups mix objects one row per package since schema `v3` |
| #126 | `08-reclamation` | reclamation's most important rail had no test; and the helper it used contradicted the spec on an unparseable timestamp |
| — | `06-the-run` | `#failure-not-error` claimed one non-zero exit condition; there are two |
| — | `09-cli` | `08-reclamation#rails` described a `--dry-run` switch that has never existed |

The last two were errors in this specification, caught by later items in the same
effort. That the spec caught the spec is worth more than if it had only caught the
code: the code was right both times, and the description is what a reader acts on.
