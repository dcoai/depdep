# Depdep

Do a piece of build work **once per distinct build**, and restore it everywhere
else.

Depdep is a content-addressed store for build artifacts, with three providers:
compiled Elixir dependencies, Debian packages, and git mirrors. Each keys its
objects in the way that is actually sound for that kind of artifact, and those
ways differ sharply — a `.deb` needs nothing more than its own filename, while a
compiled dependency needs a hash of everything that went into it.

The mix provider is the deepest of the three, and the three sections that follow
are about it. **It stores each compiled Elixir dependency as its own object,
keyed by a recursive Merkle hash over that dependency's entire input closure.** A
restore is therefore only ever the build the consumer would have produced itself.
For the other two, see [apt](#caching-apt-packages-too) and
[git](#mirroring-git-repositories).

*On the name: it was shortened from "dependency depot", back when a dependency
was the only thing it stored. The packages and the mirrors came later, and the
name stayed.*

## What problem this solves

Two different ones, depending on the shape of the project.

**In a poncho** — several independent Mix projects in one repository, each with
its own `deps/` and `_build/` — the same package is compiled once per member.
Measured on the project this was extracted from: 564 dependency instances over
113 distinct packages, with `ash` compiled ten times at 44 s a pass. Depdep
collapsed that to 148 stored objects and cut CI from ~28 minutes to 6m24s.

**In a single project** the win is across *pipelines* rather than members:
compiled dependencies persist between CI runs. That is what a CI cache normally
does — the difference is correctness, below.

## Why not just use a CI cache

A CI cache is one opaque archive per key, restored wholesale, after which Mix
decides what is stale by comparing source mtimes against build manifests. **A
cache restore steps around the machinery Mix uses to stay correct**, and the
failure is silent: you get a build that compiles clean, passes its tests, and is
wrong.

Depdep's key is computed from the inputs, so a stored object either matches what
you would have built or is not returned at all.

## Why the hash recurses

A dependency's compiled output is a function of its dependencies' compiled
output, not merely of their version numbers. `use Spark.Dsl` expands spark's
macros **into ash's beam files**; bump spark and ash's correct bytecode changes
while ash's own version and inner checksum stay byte-identical.

Mix handles this correctly during a normal build by tracking compile-time
dependencies. A cache layer has to re-establish that invariant for itself:

```
key(dep) = sha256(
  schema_version,
  name, version, inner_checksum,        # the dep's own source
  elixir, otp, mix_env, build_tools,    # the toolchain
  config_digest(dep.app),               # compile-time config reaching it
  for each declared child, sorted:
    optional and absent -> ("absent",  name)
    otherwise           -> ("present", name, key(child))   # <- recursion
)
```

Compile-time configuration is in the key for the same reason: `Application.compile_env/2`
and module-level attributes bake values into bytecode, so two members that
configure a package differently need different objects.

## Why no dependencies

Depdep runs **before `mix deps.get`**. Anything it depended on would have to be
fetched by the very machinery it exists to get in front of. AWS Signature v4 is
about sixty lines, and `:httpc` and `:erl_tar` ship with OTP, so the whole client
is written out here rather than taken from a library.

This is a hard constraint, not a preference. See `mix.exs`.

## Failure is not an error

Any problem reaching the store — no credentials, unreachable host, wrong secret,
a corrupt object — is reported and then ignored, and the run exits 0. The worst
outcome of a broken depot is that Mix compiles the dependency, which is what it
would have done anyway. A build tool that can fail your pipeline for a *cache
miss* has made things worse.

**Two files sit outside that promise, and it is worth being exact about which.**
Depdep reads your `mix.lock` and your `config/config.exs`; if either cannot be
read, the run exits non-zero rather than carrying on. That is deliberate. A
lockfile that does not parse is one `mix deps.get` cannot parse either, so the
pipeline was going to stop at the next command regardless — depdep stops it one
command earlier and names the file. What it never does is absorb a broken
project into a slow one.

## Getting started

### 1. What you need

- An S3-compatible object store. MinIO is what this was built against; anything
  speaking Signature v4 will do.
- A bucket, and an identity with **Get and Put on that bucket — and nothing
  else**. Depdep never deletes, and an identity that cannot delete is one that
  cannot be talked into wiping your store.
- Elixir 1.15 or later on the machine that runs it.

### 2. Point it at the store

Four environment variables. The first two are not secret and belong with the
rest of your build's shape; the second two are credentials and belong wherever
your CI keeps those.

| variable | example | |
|---|---|---|
| `DEPDEP_ENDPOINT` | `http://10.0.0.5:9000` | required |
| `DEPDEP_BUCKET` | `elixir-dep-store` | required |
| `DEPDEP_ACCESS_KEY` | `depdep` | required |
| `DEPDEP_SECRET_KEY` | | required, keep it masked |
| `DEPDEP_REGION` | `us-east-1` | optional, this is the default |
| `DEPDEP_ENABLED` | `false` | optional, unset means enabled |
| `DEPDEP_CONCURRENCY` | `1` | optional, an instrument — see below |
| `DEPDEP_METRESIS_URL` | `http://metresis:2060` | optional, both or neither |
| `DEPDEP_METRESIS_TOKEN` | `mtr_ing_…` | optional, keep it masked |

**If any of them is unset, depdep says so and exits 0.** Nothing breaks; Mix
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

### Reporting to metresis

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
    depdep.saved_total  the run's hits together              seconds

Samples carry `provider`, `unit`, `bucket` and `reason` as labels, and the run
carries the project, commit, ref, pipeline and job that GitLab already puts in
the environment — so **no pipeline needs editing**. The token names the domain,
so depdep never says where to write.

**The vocabulary is `priv/profiles/depdep.exs`**, the profile metresis §3.3 calls
for — units, polarity, descriptions, the label keys and their expected values,
and a starter dashboard — owned here because the metrics are depdep's.
`mix depdep.profile check` holds it to what the code emits, both ways, and runs
in CI: a metric added without it cannot land, and neither can a definition
nothing will ever fill. On every `v*` tag, `mix depdep.profile publish` POSTs
it to `DEPDEP_METRESIS_URL` with an admin token
(`DEPDEP_METRESIS_ADMIN_TOKEN`, a protected variable that exists only for tag
pipelines) and adopts it on the CI domain — so a release is what brings new
definitions, and nobody adopts anything by hand.

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

### 3. Add the bootstrap script

Depdep runs *before* `mix deps.get`, so it cannot be a dependency in your
`mix.exs` — that would be circular. Commit this as `scripts/depdep.exs`:

```elixir
Mix.install([{:depdep, "~> 0.5"}])

Depdep.CLI.main(System.argv())
```

`Mix.install/2` fetches into its own cache, independent of your project's
`deps/`, so there is no ordering problem and no root Mix project required.

**Until depdep is on hex.pm — and as of this version it is not; v0.5.0 will be
the first release published there — install it from git instead.** The git
form also stays the way to run a commit that has no release yet:

```elixir
# A private repository's URL has to carry credentials, and what is available
# differs between a developer's machine and a CI container: a developer has an
# ssh key, a job has CI_JOB_TOKEN and no key at all.
url =
  case System.get_env("CI_JOB_TOKEN") do
    nil -> "git@gitlab.example.com:group/depdep.git"
    token -> "https://gitlab-ci-token:#{token}@gitlab.example.com/group/depdep.git"
  end

Mix.install([{:depdep, git: url, tag: "v0.4.0"}])

Depdep.CLI.main(System.argv())
```

**For the CI half to work, depdep must allow it.** In depdep's
*Settings -> CI/CD -> Job token permissions*, add the consuming project to the
allowlist — otherwise the clone comes back 404 and you will think the tag is
wrong. If depdep is public on your instance, skip all of this and use the plain
`https://` URL with no credentials.

### 4. Wire it into CI

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
source is on disk and Mix has resolved the graph, so depdep asks Mix for it and
keys those dependencies properly. This used to be a second `--pull` line the
consumer had to remember (and two of four did not); with `--mix-get` it is
depdep's own second pass, over only the units the first could not settle. The
same pass re-reads the `MIX_ENV` question with the graph in hand, so a
dependency the first pass could only call "maybe outside this env" is settled
exactly.

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
such. The number is written beside the build (`_build/<env>/.depdep/<name>.compile`)
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

### 5. Poncho projects

Several independent Mix projects in one repository, each with its own `deps/`
and `_build/`. **Nothing needs to be said** — depdep treats every `mix.exs`
beneath the root as a member, at any depth, and a package compiled for one is
restored for the others whenever the inputs agree. A root `mix.exs` of its own
makes no difference: a poncho with a root coordinator project gets the root
*and* its members, not the root instead of them.

A `mix.exs` with no `mix.lock` beside it is not a member — there is nothing to
key without a lock — which is what separates buildable members from path
dependencies a parent compiles. Depdep says how many it passed over, once, so
the number is never a surprise:

```
depdep: 14 directories have a mix.exs but no mix.lock — not members, nothing to key
```

**First, check that you need this.** If your members can share one build — an
umbrella, or plain projects pointing `build_path`, `deps_path`, `config_path`
and `lockfile` at a common root ([`Mix.Project`](https://hexdocs.pm/mix/Mix.Project.html),
which is all an umbrella does) — then Mix already compiles each package once
for all of them, at no cost and with no store to run. Do that instead.
Depdep's poncho case is for members that deliberately *cannot* share a build:
independent dependency sets, members on different toolchains, or a boundary
between them that has to stay real.

**Where a member compiles to is asked of the member, not assumed.** Almost every
project builds into `_build/<env>`, and depdep used to take that literally. A
project that sets `build_path` in its `mix.exs` — because two variants cannot
share one build, say — compiles elsewhere, and depdep would restore into a
directory Mix never reads: a restore *and* a full compile, with nothing
reporting a problem. It now asks `Mix.Project` for each member's build path, so
`build_path: "_build/sqlite"` is found and used.

The same goes for `config/config.exs`: it is evaluated with the member's
`mix.exs` loaded, so config that calls a function from its own project module
— choosing an Ecto adapter, say — or asks `Mix.Project.build_path()` for
esbuild's `NODE_PATH` sees the member's answers. Evaluated with no project
loaded, the first raised and the second answered from whichever directory
depdep was run from, which put the cwd into a key.

The build path is deliberately **not** part of any key. Identical bytecode does
not depend on the directory it was written to, so two variants of a project that
differ only in where they build share their dependency objects, which is the
point.

Two options for when the default is wrong:

```sh
# a member on a different toolchain has nothing to share, so skip the scan.
# --exclude takes a path prefix, matched on whole segments: this drops
# clients/wasm and leaves clients_vendor/ alone.
elixir scripts/depdep.exs --pull --exclude clients

# and since a toolchain varies per member, not per top-level group, a prefix
# can go as deep as it needs to
elixir scripts/depdep.exs --pull --exclude logic-analyzer/eval

# or name the members explicitly, which always wins over discovery
elixir scripts/depdep.exs --pull --project platform/crm --project hosts/app
```

This is where the deduplication is largest: the project this was extracted from
compiled 564 dependency instances over 113 distinct packages every pipeline.

### 6. Check it is working

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
  one git dependency can account for several. After `deps.get` depdep asks Mix
  for the graph and keys them, so with `--mix-get` a git dependency ends the
  same invocation `pulled` or `missing`, never `skipped`. A `skipped N` that
  persists across the second pass is worth reading: it is a dependency Mix did
  not resolve for this env at all.
- **`not for this env N`** is a lock entry the current `MIX_ENV` never builds:
  `ex_doc` and its chain under `MIX_ENV=test`, say, when it is declared
  `only: :dev`. The lock lists every dependency resolved under *any*
  environment, and depdep used to ask the store for all of them — a `GET` per
  job that could only ever miss, since no `--push` from a test job will ever
  produce a compiled `ex_doc`. Decided from your `mix.exs` and the lock's own
  edges before any key is computed or any request made, and kept out of
  `missing` so that number can reach zero and mean it.

  One honest limit: before `mix deps.get`, a git dependency's own dependencies
  are unknown, so a lock entry the walk did not reach *might* be one of them.
  Rather than guess, depdep requests those as it always did and says so once —
  `N dependencies may be outside MIX_ENV=test but are requested anyway`. A pull
  after `deps.get` has the graph and decides exactly.

To confirm the store is being used at all rather than a CI cache underneath it,
look for zero recompiles of dependencies in the compile output: every `==>` line
should be your own code.

## Caching apt packages too

A job that installs a few packages before it builds re-downloads them from a
Debian mirror every pipeline. The same depot can hold those, with the same
credentials and the same fail-safe rules — `--provider apt`.

**This one is simple, and it is meant to be.** `Depdep.Key` recurses because an
Elixir dependency's compiled output is a function of its dependencies' compiled
output. A `.deb` has no such property: the distribution built it once for
everyone, its contents do not change when its dependencies change, and
`name_version_arch.deb` already identifies it exactly. **So the key is the
filename**, the object is the `.deb` itself, and nothing is hashed.

```yaml
variables:
  # one place, so the list cannot drift out of step with itself
  APT_PACKAGES: "libsodium-dev imagemagick"

script:
  # Debian images delete each .deb as it installs. Without this, --push finds
  # an empty directory and the store never warms.
  - rm -f /etc/apt/apt.conf.d/docker-clean
  - apt-get update
  - elixir scripts/depdep.exs --pull --provider apt ${APT_PACKAGES// / --package }
  - apt-get install -y $APT_PACKAGES
  - mix test
  - elixir scripts/depdep.exs --push --provider apt
```

- **`--pull` asks apt what it is about to fetch** — `apt-get install
  --print-uris` — and restores those files into `/var/cache/apt/archives`.
  `apt-get install` looks there before it reaches for the network. Depdep's job
  ends at populating a directory; it never runs apt for you, edits your sources,
  or takes a view on your pipeline.
- **`--push` reads that directory** and uploads whatever the store does not
  already have. It does not ask apt again — once the packages are installed,
  `--print-uris` reports nothing, because apt has nothing left to fetch.
- **Run `apt-get update` first.** Without a package index apt cannot resolve
  anything, and depdep will say so and restore nothing rather than guess.
- **Delete `/etc/apt/apt.conf.d/docker-clean` before installing.** Debian's
  images ship it, and it deletes every `.deb` as it is installed — so `--push`
  finds an empty archives directory, uploads nothing, and the store never warms.
  Nothing fails; it simply looks as though the provider does not work. Setting
  `APT::Keep-Downloaded-Packages "true"` does the same job.
- **`git` cannot be one of the packages depdep serves you.** `Mix.install`
  clones depdep, so git has to be in the image already — it is needed before
  depdep can bootstrap at all, let alone restore anything.
- **Depdep must run in the same container as the `apt-get install` it serves.**
  That is what makes `--print-uris` trustworthy: it is apt, in the environment
  that will do the installing, reporting exactly what it would fetch. Run it
  somewhere else — a different base image, the runner host — and it answers for
  the wrong machine.
- **Restored packages are verified** against the checksum apt itself reported.
  A mismatch is a miss, so apt downloads it; a corrupt object never reaches a
  package manager. The mix provider has no equivalent, because nothing tells it
  what a compiled dependency should hash to.
- `--apt-cache-dir` moves the directory if yours is not the default
  `/var/cache/apt/archives`.

Objects live under `apt/v1/<distribution>-<codename>/`, so they can be browsed,
and so two distributions cannot collide on a filename:

```
apt/v1/debian-trixie/libsodium-dev_1.0.18-1_amd64.deb
```

Nothing about this changes the mix provider. With no `--provider`, depdep does
exactly what it did before, so an existing bootstrap script keeps its meaning.

## Mirroring git repositories

A job that clones a large repository pays for it every pipeline. `--provider git`
keeps a bare mirror in the depot; the consumer clones against it and transfers
almost nothing.

```yaml
script:
  - elixir scripts/depdep.exs --pull --provider git --repo "$BIG_REPO"
  - git clone --reference .depdep/git/$(basename $BIG_REPO .git).git --dissociate "$BIG_REPO" checkout
  - elixir scripts/depdep.exs --push --provider git --repo "$BIG_REPO"
```

Measured against `github.com/philss/rustler_precompiled`, a 7.4 MB repository:

```
cold clone                        2.43 s
clone against a restored mirror   0.57 s
```

**A stale mirror is not a wrong answer, and that is the whole design.** A wrong
mix object is a build that compiles clean, passes its tests and is wrong — which
is why `Depdep.Key` recurses over the entire input closure. A mirror is only a
*seed*: whatever it holds, your own clone reconciles it against the real remote,
so an out-of-date mirror costs a slightly larger transfer and nothing else.

That is what lets the key be cheap. An object is keyed on the repository and the
**month**, not on a commit:

```
git/v1/github.com-philss-rustler_precompiled/2026-09/mirror.tar.gz
```

- Each monthly object is written once and never modified, so the store stays
  append-only.
- Storage is bounded by months rather than by commits — keying per commit would
  store a full mirror per push.
- The worst case is **one cold clone per repository per month**: the first
  pipeline of the month misses, clones normally, and its `--push` stores the
  mirror for every pipeline after it. Nothing to schedule and nothing to
  bookkeep.
- `--push` produces the mirror itself when the store does not already have this
  month's, so the store fills without anyone priming it.
- `--git-mirror-dir` moves the mirrors if `.depdep/git` does not suit.

`git@host:group/proj` and `https://host/group/proj.git` are the same repository
and share one mirror, so reaching it two ways does not store it twice.

## Reclaiming the store

The store is append-only: pipelines can read and write, and nothing they run can
delete. That is deliberate — an identity that cannot delete is one that cannot be
talked into wiping your store — and it means the store only grows.

Growth is per *generation*, not per pipeline. One Elixir or OTP bump changes
every key at a stroke; a dependency bump orphans that package and everything
above it; and a git mirror is stored per repository per month whether or not
anything changed.

### What is still needed

Every `--pull` records what that consumer wanted, in a small object under
`roots/`. Reclamation keeps whatever the recent roots reference.

This is the last-access rule you would want, expressed where it can be. Neither
MinIO nor S3 can expire on last access — both compute expiry from an object's
*creation* date, which says nothing about whether anything still uses it. But a
consumer that builds refreshes its roots, and one that has not built for a while
ages out of them. A quarterly release branch keeps its objects for as long as it
keeps building, and stops mattering when it stops.

```sh
# read-only, and safe with the credentials a pipeline holds
elixir scripts/depdep.exs --report
```

### Removing it

```sh
# says what it would remove, and removes nothing
elixir scripts/depdep.exs --sweep

# actually removes it
elixir scripts/depdep.exs --sweep --confirm
```

**Run this as an operator, with an identity that can delete.** A sweep with
pipeline credentials fails on permissions, which is the right way round: the
guard is the credential, not the flag.

**A wrong deletion costs a recompile, never correctness.** Delete something still
needed and the next pipeline misses it, compiles it, and pushes it back. That is
not true of most caches and it is why this can afford to be aggressive — but it
is still a cost, so there are three rails:

- **Nothing is deleted without `--confirm`.**
- **`--grace DAYS`** (default 2) never touches anything created that recently, so
  a push racing the listing is not swept.
- **No current roots means no sweep.** A store nobody uses and a misconfigured
  invocation look identical from the outside, and one of them would have this
  delete everything. It refuses and tells you to look at `--report` first.

Each provider is reclaimed by the rule that actually fits it:

| prefix | rule | why |
|---|---|---|
| `v2/` (mix) | what no current root names | churn-driven, and the live set is exactly known |
| `git/v1/` | newest `--keep-epochs` per repository (default 2) | a mirror is a seed; an older one is superseded, not unreachable |
| `apt/v1/` | never | small, near-static, shared by every consumer, and its live set needs apt in the right container |
| `roots/` | older than `--within` (default 30 days) | they only accumulate when a branch dies |

## Prior art

Depdep is not the first attempt at this problem, and one of the earlier ones is
the better answer if you are already set up for it. Worth knowing what you are
choosing between.

### Nix is the closest relative

[`deps_nix`](https://github.com/code-supply/deps_nix) and
[`mix2nix`](https://github.com/ydlr/mix2nix) turn each `mix.lock` entry into
its own Nix derivation. A Nix store path is a hash over that derivation's
inputs, and those inputs include the store paths of the children it was built
against — **the same recursion this README spends a section arguing for, except
obtained by construction rather than by argument.** Put a binary cache behind
it and you have depdep's restore, with reported CI reductions in the same
range. If you already run Nix, use it; nothing here is worth adding a second
mechanism for.

Two differences, and the first is the substantive one:

- **Compile-time configuration is part of depdep's key.** A dependency's
  derivation is a function of *that dependency's* inputs. Your
  `config/config.exs` is not among them — it belongs to the consumer project,
  outside the dependency entirely. But `Application.compile_env/2` and
  module attributes bake values from it into the dependency's bytecode, which
  is why two members that configure the same package differently need
  different objects. `Depdep.Config` puts a per-app slice of exactly that
  configuration into the key. What a derivation-keyed store returns in that
  situation is a question worth asking of whichever tool you pick.
- **No Nix, and no generated file to keep in sync.** Depdep reads `mix.lock`
  at the moment it runs, so there is no checked-in derivation set that can
  drift from the lock it was generated from.

### Bazel is the general answer, and is not available here

Action-level content hashing plus a remote cache is this problem solved in
general, for every language at once. It is not an option on the BEAM today:
[`rules_erlang`](https://github.com/rabbitmq/rules_erlang) is unmaintained —
RabbitMQ moved back to erlang.mk once it caught up — and there is no working
`rules_elixir`. Worth knowing so you don't go looking.

### Precompiled artifacts are the ecosystem's precedent, not a competitor

[`rustler_precompiled`](https://github.com/philss/rustler_precompiled),
[`elixir_make`](https://github.com/elixir-lang/elixir_make) with
[`cc_precompiler`](https://hexdocs.pm/cc_precompiler/precompilation_guide.html),
and [Nerves](https://hexdocs.pm/nerves/) system artifacts all say "download
this rather than compile it", so the idea needs no defending here. The
mechanism is a different one: those artifacts are *publisher*-produced, keyed
on package version plus target triple, and cover native code. Depdep's are
*consumer*-produced, keyed on the whole input closure, and cover Elixir
bytecode. They do not overlap, and a project can use both.

### Mix itself

Two open issues describe this problem from inside Mix.
[elixir-lang#12520](https://github.com/elixir-lang/elixir/issues/12520)
proposes keeping compiled dependencies in `_build` **keyed by version**, so
switching branches stops costing a recompile — the local form of what depdep
does across machines, under exactly the key `Depdep.Key` shows to be unsound:
bump `spark` and `ash`'s version does not move while its correct bytecode does.
[elixir-lang#14425](https://github.com/elixir-lang/elixir/issues/14425) covers
git dependencies against CI caches. Both are open.

[Elixir 1.19](https://elixir-lang.org/blog/2025/10/16/elixir-v1-19-0-released/)
attacks the same wall-clock cost from the other end:
`MIX_OS_DEPS_COMPILE_PARTITION_COUNT` compiles dependencies in parallel across
OS processes, reportedly up to 4x faster. **These compose, and you want both.**
Depdep removes compilations; 1.19 makes the remaining ones cheaper — and the
set it makes cheaper is precisely depdep's `missing N`.

## Status

**In use.** Depdep runs first in the CI of the projects it was built
alongside, restoring compiled Elixir dependencies and Debian packages on every
pipeline. It found its first two defects there — a 403 on any key holding a
reserved character, and a `build_path` that made it serve a directory Mix never
reads — both fixed in v0.1.0. What each release changed is in
[CHANGELOG.md](CHANGELOG.md).

**Measured.** The pipeline this was extracted from went from ~28 minutes to
6m24s across 148 stored objects, with zero dependencies recompiled. The
extraction was verified against that store: the same eleven projects compute
**564 byte-identical keys**, and every object already there is one this code
asks for. That remains the best evidence the key rules are right. On current
pipelines a pull costs 1.3–1.6 s for 44 Debian packages and 3.2–4.2 s for
~50 compiled dependencies, over the network. A restored git mirror measured
2.43 s cold against 0.57 s on a 7.4 MB repository.

**Not yet verified, and worth knowing before relying on it.** Each mechanism
below is tested; the pipeline-level confirmation is what is missing.

- **The concurrency speedup is a synthetic figure.** 200 objects, 4.40 s to
  0.16 s, against a local socket with injected latency — an upper bound, not a
  prediction. `DEPDEP_CONCURRENCY=1` exists so the real comparison is two
  pipelines on one commit; it has not been run, and job-duration noise on a
  busy runner is 20–40× depdep's whole cost, so it needs interleaved repeats
  and a narrow timing window rather than one before/after pair.
- **Nothing has watched `apt-get install` consume a restored `.deb`.** A root
  job restores every file apt said it would fetch (`missing 0`) and the install
  succeeds, but it runs `apt-get install -qq`, which hides the fetch lines that
  would prove apt used the file rather than re-downloading it. The check is one
  `-q` instead of `-qq`, or a read of `/var/log/apt/history.log`.
- **Reclamation has never run against a real bucket.** The rules are tested and
  the S3 verbs are exercised over a socket, but no `--report` or `--sweep` has
  seen a live store.

**Not on hex.pm yet.** The package builds (`mix hex.build`) and carries its
license, but v0.5.0 will be the first version published; until then install it
from git as [Getting started](#3-add-the-bootstrap-script) shows.
