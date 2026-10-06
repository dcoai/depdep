# Getting started

*Part of [depdep's guide](../README.md#the-guide). Back to the [README](../README.md).*

## 1. What you need

- An S3-compatible object store. MinIO is what this was built against; anything
  speaking Signature v4 will do.
- A bucket, and an identity with **Get and Put on that bucket — and nothing
  else**. Depdep never deletes, and an identity that cannot delete is one that
  cannot be talked into wiping your store.
- Elixir 1.15 or later on the machine that runs it.

## 2. Point it at the store

Two environment variables. The first is the shape of the store and belongs
with the rest of your build's configuration; the second is the credential and
belongs wherever your CI keeps those.

```
DEPDEP_STORE=s3://depdep@10.0.0.5:9000/elixir-dep-store?region=us-east-1
DEPDEP_SECRET_KEY=…                                    # masked
```

`s3://` is a plain-http endpoint, `s3+https://` is TLS; the userinfo is the
access key; the path is the bucket; `region` defaults to `us-east-1`. **The
secret is never in the URL** — one with a password is refused — because a URL
ends up in a shell history and a masked variable does not. Or, separately:

| variable | example | |
|---|---|---|
| `DEPDEP_ENDPOINT` | `http://10.0.0.5:9000` | required |
| `DEPDEP_BUCKET` | `elixir-dep-store` | required |
| `DEPDEP_ACCESS_KEY` | `depdep` | required |
| `DEPDEP_SECRET_KEY` | | required, keep it masked |
| `DEPDEP_REGION` | `us-east-1` | optional, this is the default |
| `DEPDEP_ENABLED` | `false` | optional, unset means enabled |
| `DEPDEP_CONCURRENCY` | `1` | optional, an instrument — see below |
| `DEPDEP_METRESIS` | `http://metresis:2060` | optional, both or neither (`DEPDEP_METRESIS_URL` also works) |
| `DEPDEP_METRESIS_TOKEN` | `mtr_ing_…` | optional, keep it masked |

Both forms at once is refused, not merged. **If the store is unset, depdep
says so and exits 0.** Nothing breaks; Mix
compiles the dependency as it always would. You can wire depdep into a pipeline
before the credentials exist and nothing will fail.

**`DEPDEP_ENABLED=false` turns depdep off**, wherever your CI lets you set a
variable — one job, one branch, one pipeline. It reports that it is off and
exits 0 before reading your lockfile, your config or the store's credentials,
so it is also the switch to reach for on a day when depdep itself is the
suspect. Unset means enabled, so ignoring this variable is the same as never
having heard of it.

Its first use is measurement. Comparing a cached pipeline against a cold one
used to mean unsetting `DEPDEP_ENDPOINT` — editing the store's configuration to
take a reading, and remembering to put it back. A value that is neither `true`
nor `false` is refused rather than guessed at, because a baseline quietly served
from the store is worse than no baseline.

**`DEPDEP_CONCURRENCY` is an instrument, not a tuning knob.** Unset — which is
what every real run should be — depdep derives the number from the scheduler
count, clamped so a small laptop still overlaps usefully and a large runner does
not open a session per core against one store. Setting it overrides that
derivation exactly, without the clamp, so `DEPDEP_CONCURRENCY=1` is a genuinely
serial run: one connection, one transfer at a time.

It exists because a speedup claim has to be falsifiable. Depdep's concurrency
figure was measured against a local socket with injected latency, and
concurrency was the one variable in that claim that could not be varied without
checking out an older commit — which moves five other things at the same time
and makes the difference unattributable. With this, the comparison is two
pipelines, one commit, one variable.

If a measurement shows the derived value is wrong, the fix is to change the
derivation rather than to tell anyone to set this. A value that is not a
positive integer, or one above the ceiling of 256, is refused rather than
clamped — substituting a number you did not ask for would label the run with a
concurrency it never used, which is the failure the variable exists to avoid.

## Reporting to metresis

**With `DEPDEP_METRESIS_URL` and `DEPDEP_METRESIS_TOKEN` both set**, depdep posts
what a run cost to a metresis instance. With either unset it sends nothing and
opens no connection.

Why bother, when the summary line already prints a duration: because one sample
of a pipeline timing answers nothing. Job durations on a busy runner vary three
to four times over on *identical code*, against a depdep cost of a few seconds.
Only a series separates a real regression from a noisy afternoon.

    depdep.elapsed      the whole run                        seconds
    depdep.span         one provider's concurrent phase      seconds
    depdep.download     one unit, off the network            seconds
    depdep.extract      one unit, unpacked (or tarred)       seconds
    depdep.bytes        one unit, compressed                 bytes
    depdep.bytes_total  one provider                         bytes
    depdep.units        one provider, one bucket             count
    depdep.concurrency  transfers allowed at once            number
    depdep.parallelism  work done ÷ wall-clock               number
    depdep.compile      one unit, compiled on a miss         seconds  (--compile-deps)
    depdep.saved        one unit, a hit's compile not done   seconds  (lower bound)
    depdep.compile_carried  one unit, what the object says it cost   seconds
    depdep.saved_total  the run's hits together              seconds
    depdep.rebuilt_after_restore  restored, but Mix would rebuild it  count

Samples carry `provider`, `unit`, `bucket` and `reason` as labels, and the run
carries the project, commit, ref, pipeline and job that GitLab already puts in
the environment — so **no pipeline needs editing**. The token names the domain,
so depdep never says where to write.

**The vocabulary is `priv/profiles/depdep.exs`**, the profile metresis §3.3 calls
for — units, polarity, descriptions, the label keys and their expected values,
and a starter dashboard — owned here because the metrics are depdep's.
`mix depdep.profile check` holds it to what the code emits, both ways, and runs
in CI: a metric added without it cannot land, and neither can a definition
nothing will ever fill.

**The profile travels with the data.** Every post carries a header,
`Metresis-Profile: depdep sha256:<hash of the document>`. An instance that
holds that hash for your token accepts the post as usual; one that does not
answers `428 profile_missing`, and depdep publishes the document with the same
ingest token and retries the post once — two round-trips per depdep version
per instance, ever, and nothing for anyone to run by hand. Whether the
publish applies at once or waits for a member's approval is the token's
**capability** (`profile` or `propose`, set when it is minted): while a
proposal is pending, posts whose metrics are all already defined keep flowing,
and depdep says once that samples for new metrics wait. A token with neither
capability is never refused — the data lands as provisional, as it always
did, and depdep says once that the token cannot carry a profile. Nothing in
any of this can fail your pipeline.

`depdep.parallelism` is the one worth explaining. Units transfer 8–32 at a time,
so the summed per-unit time normally *exceeds* the wall-clock span containing
it, and the ratio is how many were genuinely in flight. Read against
`depdep.concurrency` it says whether the limit was the constraint: a parallelism
of 6 under a limit of 32 means raising the limit would do nothing.

**Nothing here can fail your pipeline.** A refused connection, a 401, a 500 or a
hang is a warning and an exit 0, on a short timeout of its own — the numbers are
a by-product of work that already succeeded. The `Idempotency-Key` is derived
from the pipeline and job rather than the clock, so a retried job cannot
double-count.

## 3. Add the bootstrap script

Depdep runs *before* `mix deps.get`, so it cannot be a dependency in your
`mix.exs` — that would be circular. Commit this as `scripts/depdep.exs`:

```elixir
Mix.install([{:depdep, "~> 0.9"}])

Depdep.CLI.main(System.argv())
```

`Mix.install/2` fetches into its own cache, independent of your project's
`deps/`, so there is no ordering problem and no root Mix project required.

**Until depdep is on hex.pm — and as of v0.9.0 it is not; publishing is a
separate decision from tagging — install it from git instead.** The git form
also stays the way to run a commit that has no release yet:

```elixir
# A private repository's URL has to carry credentials, and what is available
# differs between a developer's machine and a CI container: a developer has an
# ssh key, a job has CI_JOB_TOKEN and no key at all.
url =
  case System.get_env("CI_JOB_TOKEN") do
    nil -> "git@gitlab.example.com:group/depdep.git"
    token -> "https://gitlab-ci-token:#{token}@gitlab.example.com/group/depdep.git"
  end

Mix.install([{:depdep, git: url, tag: "v0.9.0"}])

Depdep.CLI.main(System.argv())
```

**For the CI half to work, depdep must allow it.** In depdep's
*Settings -> CI/CD -> Job token permissions*, add the consuming project to the
allowlist — otherwise the clone comes back 404 and you will think the tag is
wrong. If depdep is public on your instance, skip all of this and use the plain
`https://` URL with no credentials.

## 4. Wire it into CI

```yaml
script:
  - elixir scripts/depdep.exs --pull --mix-get --compile-deps || mix deps.get
  - mix compile
  - mix test
  - elixir scripts/depdep.exs --push     # upload what the store lacked
```

One line does three things, in an order that matters: it restores what the
store has, runs `mix deps.get` to fetch only what it did not, and then decides
again whatever could not be decided before the source was on disk. The
`|| mix deps.get` is for the day depdep itself cannot start — its repository
unreachable for `Mix.install`, say — so the job goes cold rather than red. If
`deps.get` failed *inside* depdep it fails again outside, with the same error,
and the job stops where it always would have.

**Why the second decision.** A git lock entry records url, ref and opts and no
dependency list, so before `mix deps.get` there is no way to know what it
depends on — and since a dependency's compiled output is a function of its
dependencies', it cannot be keyed, and neither can anything above it. One
badly-placed fork disables caching for its whole cone. After `deps.get` the
source is on disk and Mix lists its children, so depdep keys those
dependencies properly. This used to be a second `--pull` line the consumer had
to remember (and two of four did not); with `--mix-get` it is depdep's own
second pass, over only the units the first could not settle. The same pass
asks the `MIX_ENV` question with Mix's list complete, so a lock entry the
first pass could only request is settled exactly.

**What `--mix-get` changes about failure.** `--pull` alone never fails a job.
With `deps.get` inside it, a fetch that fails has to fail the job exactly as the
bare `mix deps.get` line it replaced did — that is the consumer's fetch, not the
store's — so `mix deps.get`'s exit status becomes depdep's, after the summary
line and the metrics for what the pull did manage. Store trouble stays a warning
and exit 0, and with no store configured at all `deps.get` still runs.

**`--compile-deps` compiles exactly what the pull left missing, timed.** After
`deps.get`, depdep runs one `mix deps.compile <names>` per member naming only
the misses (and the units it cannot key, which a miss may depend on). Restored
dependencies are never mentioned, so Mix never looks at them; your own
`mix compile` line, untouched, then finds every dependency up to date and
compiles only the project. Nothing is compiled twice. Mix's output is forwarded
as it is, and each dependency's compile time is read off the boundaries Mix
already prints — `==> jason` to `Generated jason app` — so there is no
`MIX_DEBUG` noise and nothing to parse in your pipeline. rebar3 dependencies
print no end marker, so theirs runs to the next boundary and is labelled as
such. Every miss named is one Mix's own list says this env builds, so none is
refused. The number is written beside the build (`_build/<env>/.depdep/<name>.compile`)
for `--push` to carry with the object, and posted as `depdep.compile`.

This is the one place depdep may fail a job: a dependency that does not compile
ends the run with Mix's exit status. That is your compile, surfaced one line
earlier with the same error, not the store's — and it is why the switch is
opt-in.

**And then a hit says what it saved.** `--push` sends the compile time with the
object, as metadata; a `--pull` that fetches the object reads it back with one
`HEAD`, keeps it beside the restored build, and reports `saved_us` — the compile
not done, less what the download and extraction cost, never below zero. A
dependency already present saved its whole compile, and asks the store nothing.
The summary line ends with it, and metresis gets `depdep.saved` per unit and
`depdep.saved_total` per run:

```
depdep: pulled 555, missing 8, already present 0, skipped 1, not for this env 6 in 41.2s — saved ~1834.0s
```

Two honest limits. It is a **lower bound**: the source `mix deps.get` would
have fetched is saved too and cannot be attributed to one package, so it is
left out. And an object stored before this existed carries no compile time, so
a hit on it reports *nothing* — not zero — until the object is next rebuilt by
a push that measured it. A store that shows no `saved` line is one whose
objects predate `--compile-deps`, not one that saves nothing.

**And after the second pass, depdep asks Mix whether it would keep what was
restored.** A dependency Mix would rebuild anyway — its manifest records a
lock entry, an Elixir or OTP that is not this project's — is counted as a
miss with Mix's own reason on the log, `--compile-deps` compiles it, and the
summary ends `— rebuilt N`. The count posts as `depdep.rebuilt_after_restore`;
above zero it means the key missed an input, and the day it happens is the
day to look.

**Pull *before* `mix deps.get`, not after** — which is why depdep orders them
that way rather than leaving it to you. This is the one ordering mistake that
looks like it works and is not. A stored object carries both the compiled
`_build/` tree and the `deps/` source that produced it. If you fetch source
first, `mix deps.get` writes files with fresh mtimes, Mix compares those against
the restored build manifests, finds everything stale, and rebuilds all of it —
you get a perfect restore followed by a full recompile, and a pipeline *slower*
than having no store at all. Measured, on the way to getting this right: 16 of
16 dependencies restored, 16 recompiled, 9% slower than no store.

The same reasoning is why the second pass is safe when a pull after `deps.get`
would otherwise be the mistake above: an object carries **both** trees, and
`erl_tar` restores the recorded mtimes, so extracting over freshly fetched source
puts the build back ahead of it. That is asserted by a test rather than argued.

Put `--push` after the build succeeds, so a failed build cannot populate the
store. It uploads only what is missing; anything restored above is a HEAD hit
and is not re-sent.


## 5. Check it is working

The output says what happened, in the terms that matter. A cold pipeline, then
the push after the build that pipeline ran:

```
depdep: pulled 555, missing 8, already present 0, skipped 1, not for this env 6 in 41.2s
depdep: already stored 555, uploaded 8, not built here 0, skipped 1, not for this env 6 in 18.7s
```

Every bucket is printed even at zero, and the five **sum to the number of
dependencies in your lock** — 570 here. The time is depdep's own, covering the
transfer and not the `Mix.install` that bootstrapped it: a consumer's job
duration is a poor instrument, since the job around this one measured anywhere
between 126 s and 532 s on identical code. That is the point of the shape: a
number can be read as a count of packages, and a total that does not add up is
a bug worth reporting.

- **`pulled N`** and **`already stored N`** are the win — a package this build
  did not have to compile.
- **`missing N`** is a genuine miss: those inputs have no object yet, so Mix
  compiles them and `--push` stores the result. On the next pipeline they move
  into `pulled`, and `uploaded` falls to 0. **`uploaded 0` is the converged
  steady state, not a failure to write.**
- **`already present N`** is a `--pull` that found the dependency already on
  disk **and confirmed it is the right one**, so it did nothing. In CI this is 0,
  because the checkout is empty. On a developer's machine with a warm `_build`
  it is where nearly everything lands — a no-op, and the expected reading.

  Depdep records the key each tree was built or restored for, beside the build
  in `_build/<env>/.depdep/`, and compares it. Presence alone would not do:
  after a version bump both directories still exist, so a presence check skips
  the pull, `mix deps.get` writes the new source over the old build, and Mix
  recompiles — while the right object sits in the store, unrequested. That
  happened, on an `ash 3.32.3 -> 3.33.0` bump, and is why the check is as
  precise as the key.

  **Upgrading to a version with this check re-pulls everything, once.** No keys
  have been recorded yet, so the first run reports `pulled N` where it used to
  report `already present N`. It is cheap — every one is a hit — and it does not
  happen again.
- **`not built here N`** is a `--push` with nothing to offer for that
  dependency, because this project has no `deps/` + `_build/` pair for it.
  Normally it means you pushed before the build, or the build never needed
  that dependency.
- **`skipped N`** is the only number that means depdep *cannot help*: a
  dependency it will not key. Before `mix deps.get` that is every git
  dependency — the lockfile carries no dependency list for it, so no Merkle
  key can be computed — and its dependents are skipped with it, which is why
  one git dependency can account for several. After `deps.get` Mix lists its
  children and depdep keys them, so with `--mix-get` a git dependency ends the
  same invocation `pulled` or `missing`, never `skipped`. A `skipped N` that
  persists across the second pass is worth reading: it is a dependency Mix did
  not resolve for this env at all.
- **`not for this env N`** is a lock entry the current `MIX_ENV` never builds:
  `ex_doc` and its chain under `MIX_ENV=test`, say, when it is declared
  `only: :dev`. The lock lists every dependency resolved under *any*
  environment, and depdep used to ask the store for all of them — a `GET` per
  job that could only ever miss, since no `--push` from a test job will ever
  produce a compiled `ex_doc`. Decided by Mix's own list of what this env
  builds — the same converge `mix deps` runs, with `only:`, path dependencies
  and everything else Mix knows — and kept out of `missing` so that number can
  reach zero and mean it.

  One honest limit: Mix can only list a dependency's children once its source
  is on disk, so before `mix deps.get` the list is incomplete and nothing is
  excluded — every lock entry is requested, said once (`dependencies not
  fetched yet, so N lock entries are requested …`), and the second pass of
  `--mix-get` decides exactly and re-buckets the misses that were never
  buildable. Without `--mix-get` a cold checkout requests its dev-only chain
  every run; that is the shape depdep no longer optimises for.

To confirm the store is being used at all rather than a CI cache underneath it,
look for zero recompiles of dependencies in the compile output: every `==>` line
should be your own code.
