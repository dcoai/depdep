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

**If any of them is unset, depdep says so and exits 0.** Nothing breaks; Mix
compiles the dependency as it always would. You can wire depdep into a pipeline
before the credentials exist and nothing will fail.

### 3. Add the bootstrap script

Depdep runs *before* `mix deps.get`, so it cannot be a dependency in your
`mix.exs` — that would be circular. Commit this as `scripts/depdep.exs`:

```elixir
# Depdep lives in a private project, so the URL has to carry credentials, and
# what is available differs between a developer's machine and a CI container.
# A developer has an ssh key; a job has CI_JOB_TOKEN and no key at all.
url =
  case System.get_env("CI_JOB_TOKEN") do
    nil -> "git@gitlab.example.com:group/depdep.git"
    token -> "https://gitlab-ci-token:#{token}@gitlab.example.com/group/depdep.git"
  end

Mix.install([{:depdep, git: url, tag: "v0.1.0"}])

Depdep.CLI.main(System.argv())
```

`Mix.install/2` fetches into its own cache, independent of your project's
`deps/`, so there is no ordering problem and no root Mix project required.

**For the CI half to work, depdep must allow it.** In depdep's
*Settings -> CI/CD -> Job token permissions*, add the consuming project to the
allowlist — otherwise the clone comes back 404 and you will think the tag is
wrong. If depdep is public on your instance, skip all of this and use the plain
`https://` URL with no credentials.

### 4. Wire it into CI

```yaml
script:
  - elixir scripts/depdep.exs --pull     # restore what the store has
  - mix deps.get                         # fetch only what it did not
  - mix compile
  - mix test
  - elixir scripts/depdep.exs --push     # upload what the store lacked
```

**Pull *before* `mix deps.get`, not after.** This is the one ordering mistake
that looks like it works and is not. A stored object carries both the compiled
`_build/` tree and the `deps/` source that produced it. If you fetch source
first, `mix deps.get` writes files with fresh mtimes, Mix compares those against
the restored build manifests, finds everything stale, and rebuilds all of it —
you get a perfect restore followed by a full recompile, and a pipeline *slower*
than having no store at all. Measured, on the way to getting this right: 16 of
16 dependencies restored, 16 recompiled, 9% slower than no store.

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
depdep: pulled 555, missing 8, already present 0, skipped 1
depdep: already stored 555, uploaded 8, not built here 0, skipped 1
```

Every bucket is printed even at zero, and the four **sum to the number of
dependencies in your lock** — 564 here. That is the point of the shape: a
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
  dependency it will not key, almost always one taken from a git remote — the
  lockfile carries no dependency list for it, so no Merkle key can be computed.
  Its dependents are skipped with it, which is why one git dependency can
  account for several.

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

Extracted from `dco-tek/bizex`, where the original ran in CI: 148 stored
objects, zero dependencies recompiled, pipeline ~28 minutes to 6m24s.

The extraction is verified against that live store — the same eleven projects
compute **564 byte-identical keys**, and every one of the 148 objects already in
the store is one this code asks for. `dco-tek/bizex` has not yet been converted
to consume the package; that is filed there.
