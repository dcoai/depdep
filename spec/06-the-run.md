# The run

One run is one `--pull` or one `--push`, in one job. What it does between those
two words is where depdep's behaviour is least obvious from outside, and most of
it exists to keep one promise: **a restored dependency must be one Mix would
have accepted.**

Which projects a run covers is `spec/04-store-layout.md#layout`.

## A run has one direction {#direction}

A run pulls or it pushes. The two are never mixed, and every measurement a run
posts carries its direction, so a pull's numbers and a push's numbers never land
in the same average.

Read the pull side for effectiveness — what the store had. Read the push side for
what the store is being fed.

## Why there are two passes {#two-passes}

A pull runs before any source is on disk, and two things are undecidable then.

**A git dependency cannot be keyed.** Its lock entry carries no child list and
Mix has not read its `mix.exs`, so it and everything above it are `skipped`
(`spec/03-keys.md#skip`).

**Mix's list of what this env builds is incomplete.** So nothing is called
inactive: every lock entry is requested. For an entry that was outside the env
all along, that request can only end in `missing`.

With `--mix-get` the source is fetched and Mix's list becomes complete, so both
questions have exact answers. The cost of the first pass being generous is a few
extra store requests; the alternative was a hand-written walk of the lock, and
every defect that walk produced was an edge of a rule Mix already owns.

## Two converges, not one {#two-converges}

Depdep asks Mix to converge the dependencies **twice**, on purpose.

The converge that keys the units runs **before** the transfer. The converge that
asks whether Mix accepts what was restored runs **after** it — because the
manifests Mix judges arrive *with* the objects.

Two questions, two moments. Folding them into one would ask Mix about a disk it
has not seen yet.

## What the second pass decides {#second-pass}

`Depdep.SecondPass.plan/2` decides, unit by unit, whether the second enumeration
changes anything; `Depdep.SecondPass.merge/4` folds the result back.

| First pass | Second pass finds | Outcome |
|---|---|---|
| `skipped` | it can now be keyed | transferred now |
| `missing` | it is outside this env | re-bucketed, **no request** |
| anything else | — | keeps its first-pass outcome |

**One entry per unit survives.** That is what keeps the summary line and the
metrics honest: a unit is counted once, in the bucket the run ended with.

`Depdep.SecondPass` is pure, so it is tested without a store.

```test second-pass-one-entry
given a unit skipped by the first pass and transferred by the second
then the run reports it once, in its final bucket
```

## The buckets {#buckets}

This is the vocabulary the summary line, the metrics and the dashboards all use.
It is defined here and referenced elsewhere.

| Bucket | Meaning |
|---|---|
| `pulled` | the store had it and it was restored |
| `present` | already satisfied on disk; nothing was transferred |
| `missing` | the store did not have it, so it must be built |
| `skipped` | it could not be keyed, so it was never asked for |

A unit that was restored and that Mix would rebuild is **not** a hit. It is
re-bucketed as `missing` and additionally counted as `rebuilt`, below.

## The restore check {#restore-check}

A restore puts `deps/<name>` and `_build/<env>/lib/<name>` on disk carrying the
**pusher's** manifests. The consumer's Mix then judges the dependency by its own
rules: the lock entry recorded in the manifest, the Elixir and OTP it was built
with, the `.app` file's version, and `compile_env`.

Depdep never used to ask. `Depdep.RestoreCheck.statuses/2` asks, with the same
call `mix deps` makes, inside each member's project.

`Depdep.RestoreCheck.apply/2` re-buckets a restored unit Mix would rebuild as a
**miss**, with Mix's own reason, and drops its `saved_us` — the store saved
nothing there. `Depdep.RestoreCheck.count/1` counts them.

**A value above zero means the key missed an input**, on the day it happens. That
is what makes it worth reporting rather than silently repairing.

**Which input, though, is a separate question, and `--explain-rebuilt` answers
it.** Mix's commonest sentence — "the dependency build is outdated" — covers two
different causes, a recorded lock entry differing from the current one and a
manifest that cannot be read at all, and says neither. With the flag,
`Depdep.RestoreCheck.explain/1` prints what the build's manifest recorded against
what Mix expected: the Elixir and OTP pair, the SCM, and the lock entry with
**the index of the first differing tuple element** named.
`Depdep.RestoreCheck.Manifest.compare/2` is that comparison and
`Depdep.RestoreCheck.Manifest.read/1` reads the file, distinguishing a manifest
that is **absent** from one that is **unreadable** — Mix conflates them, and they
have different causes. `Depdep.RestoreCheck.Manifest.path/1` is where Mix keeps
it, printed so a reader can fetch it themselves, and
`Depdep.RestoreCheck.Manifest.differs?/1` is what decides whether there is
anything to print at all. `Depdep.RestoreCheck.Manifest` holds all three, and
reads the file directly rather than through `Mix.Dep.ElixirSCM`, which is
private and whose own reader invents a plausible-looking answer for a term it
cannot match.

It is off by default. Reporting six lines per rejected unit unprompted would,
on a warm run with hundreds of them, bury the warning it exists to explain.

```test manifest-comparison-names-the-element
given a stored manifest and what Mix expected
when they differ in the Elixir/OTP pair, the SCM or the lock entry
then the differing field is named, and for the lock the index of the first
differing tuple element
and an absent manifest is distinguished from an unreadable one
```

```test explain-rebuilt-names-the-field
given a restored unit whose manifest records a different lock entry
when the run is made with --explain-rebuilt
then the output names lock as the differing field and the element index
and without the flag it prints nothing beyond Mix's own sentence
```

Only `pulled` and `present` units are in question: a miss is already a miss, and a
skipped unit was never restored.

The converge is asked **once per member** and answers for all of that member's
units. A unit Mix does not list at all — outside the env, or not a dependency — is
absent from the answer and left alone rather than guessed at.

```test statuses-asks-mix-once-per-member
given units of one member, one of them a dependency Mix will not accept
then that one is a rebuild carrying Mix's reason and where Mix looks for the manifest
and a unit Mix does not list is absent from the answer
```

```test restore-check-rebuckets
given a restored unit Mix would rebuild
then it is counted as a miss, named with Mix's reason, and its saved time is dropped
```

## Compiling the misses {#compile-deps}

`--compile-deps` runs `Depdep.Compile.run/2`: one `mix deps.compile <names>` per
member, naming **only the misses**. `Depdep.Compile.select/2` chooses them.

Depdep knows the list from its own pull, so Mix is never asked about a restored
unit. The consumer's own `mix compile` line, untouched, then finds every
dependency up to date and compiles only the project.

Misses are named **in Mix's order**, so a dependent compiles against a dependency
Mix has just built.

The reason this exists is measurement. A per-dependency compile time exists only
at the moment a miss is compiled, and depdep never occupied that moment — the
consumer's `mix compile` did, and it prints no per-dependency timing.
`Depdep.Compile.record/2` writes each measured unit's microseconds beside the
key note, `Depdep.Compile.read/1` reads them back, and
`Depdep.Compile.saved_us/2` turns them into what a later hit saved.
`Depdep.Compile.note_path/1` is where they live — under `_build`, so anything
that cleans a build cleans them too.

Output is forwarded unchanged and timestamped on arrival;
`Depdep.Compile.Log.attribute/1` turns the boundaries into per-unit spans.

## The one place depdep may fail a pipeline {#compile-failure}

A dependency that does not compile ends the run with **Mix's exit status**, after
the summary line.

This is not a hole in `spec/01-goals-and-scope.md#failure-not-error`. The failure
is the consumer's own compile, surfaced one line earlier than it would have been,
with the same error text. The store had nothing to do with it.

It is the only non-zero exit besides a malformed invocation.

## Asking Mix about a member {#member}

`Depdep.Member.ask/3` is the one place depdep asks Mix anything about a member,
and it asks **inside the member's own project**.

Two things depdep reads are only fully defined once Mix has loaded the project:
where it builds, and what its compile-time configuration says. A
`config/config.exs` is ordinary Elixir and may call anything — a project's own
module, or `Mix.Project.build_path/0`. Evaluated with no project on Mix's stack,
the first raises and the second answers from the current directory, producing a
digest that depends on where depdep was launched from. That is precisely the
machine-dependence `spec/04-store-layout.md#compile-config` warns consumers
against in their own configuration.

**Once per run, whichever path loaded it first.** Mix keys its cache of loaded
projects by the app name it is given, so asking about a directory under a
different name recompiles its `mix.exs` and prints a redefinition warning for a
module already loaded.

depdep's own repeat questions were always a cache hit. **Mix's loads were not**: a
converge loads a path dependency's project under its real app name, so asking
about that directory as a *member* missed the cache. In a poncho whose members are
each other's path dependencies that was one warning per member per run.
`Depdep.Member.remember/2` records the name Mix used and
`Depdep.Member.remembered/1` reads it back, so the member's question reuses Mix's
cache.

It matters beyond tidiness: stderr is where every real depdep warning goes,
including `restored, but Mix would rebuild it`, and two such reports went unread
for days inside the noise.

```test mix-exs-compiles-once-per-run
given a poncho member that path-depends on another member
when depdep asks about the root and then about that member
then no redefining-module warning is printed
```

**This moves the VM's working directory** for the duration of the call. Tests
that exercise it are therefore `async: false`; a test that runs beside them and
assumes the current directory will fail in a way that looks unrelated.

## Roots {#roots}

A **root** is a small object listing the object paths one consumer wanted on one
`--pull`. `Depdep.Roots.encode/1` and `Depdep.Roots.decode/1` are its format,
`Depdep.Roots.identity/2` names the consumer, `Depdep.Roots.path/3` places it and
`Depdep.Roots.prefix/0` is where they live.

Roots exist so that reclamation has a live set (`spec/08-reclamation.md`).

**Why roots rather than checkouts.** The obvious alternative — an operator runs
`--plan` across every consumer and unions the result — fails twice. It requires
holding every consumer at the right ref and reproducing each one's exact
invocation, and getting any of that wrong *shortens* the live set, which means
over-deletion. And **it cannot see branches**: a release branch built quarterly
has a live set that exists in no checkout the operator happens to hold.

A root is produced by the thing that knows the answer, at the moment it knows it.

**It is also a last-access policy, one layer up.** Neither MinIO nor S3 can
expire on last access — both compute expiry from creation date. A consumer that
builds refreshes its roots, and one that has stopped building stops refreshing
them.
