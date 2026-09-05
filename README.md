# Dependency Depot

Compile a package **once per distinct build**, and restore it everywhere else.

Depdep stores each compiled Elixir dependency as its own object, keyed by a
**recursive Merkle hash over that dependency's entire input closure**. A restore
is therefore only ever the build the consumer would have produced itself.

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
Mix.install([
  {:depdep, git: "https://gitlab.conet.yarina.org/dco-tek/depdep.git", tag: "v0.1.0"}
])

Depdep.CLI.main(System.argv())
```

`Mix.install/2` fetches into its own cache, independent of your project's
`deps/`, so there is no ordering problem and no root Mix project required.

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
and `_build/`. **Nothing needs to be said** — with no `mix.exs` at the root,
depdep treats every `mix.exs` beneath it as a member, and a package compiled for
one is restored for the others whenever the inputs agree.

Two options for when the default is wrong:

```sh
# a member on a different toolchain has nothing to share, so skip the scan
elixir scripts/depdep.exs --pull --exclude clients

# or name the members explicitly, which always wins over discovery
elixir scripts/depdep.exs --pull --project platform/crm --project hosts/app
```

This is where the deduplication is largest: the project this was extracted from
compiled 564 dependency instances over 113 distinct packages every pipeline.

### 6. Check it is working

The output says what happened, in the terms that matter:

```
depdep: pulled 555, missing 8, skipped 1
depdep: already stored 555, uploaded 0, skipped 9
```

- **`uploaded 0`** on a repeat run means the store has converged — the good
  steady state, not a failure to write.
- **`missing N`** is a genuine miss: those inputs have no object yet, so Mix
  compiles them and `--push` stores the result.
- **`skipped N`** is a dependency depdep will not key, almost always one taken
  from a git remote — the lockfile carries no dependency list for it, so no
  Merkle key can be computed. Its dependents are skipped with it.

To confirm the store is being used at all rather than a CI cache underneath it,
look for zero recompiles of dependencies in the compile output: every `==>` line
should be your own code.

## Status

Extracted from `dco-tek/bizex`, where the original ran in CI: 148 stored
objects, zero dependencies recompiled, pipeline ~28 minutes to 6m24s.

The extraction is verified against that live store — the same eleven projects
compute **564 byte-identical keys**, and every one of the 148 objects already in
the store is one this code asks for. `dco-tek/bizex` has not yet been converted
to consume the package; that is filed there.
