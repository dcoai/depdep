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

## Status

Extracted from `dco-tek/bizex`, where it has been running in CI. This repository
is the packaging work; see the issue tracker.
