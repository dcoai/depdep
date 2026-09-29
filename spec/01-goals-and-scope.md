# Goals and scope

Depdep restores compiled build artifacts — Elixir dependencies, distribution
packages and git mirrors — from a content-addressed store, so a CI job does not
rebuild what some earlier job already built.

What depdep is chosen instead of, and why, is `spec/00-prior-art.md`.

## What depdep is for {#purpose}

Two problems, depending on the shape of the project.

**In a poncho** — several independent Mix projects in one repository, each with
its own `deps/` and `_build/` — the same package is compiled once per member.
Measured on the project depdep was extracted from: 564 dependency instances over
113 distinct packages, with `ash` compiled ten times at 44 s a pass. Depdep
collapsed that to 148 stored objects and took CI from about 28 minutes to 6m24s.

**In a single project** the win is across *pipelines* rather than members:
compiled dependencies persist between CI runs.

The second is what a CI cache normally does. The difference is correctness, and
it is the reason depdep exists rather than a configuration of something else:
`spec/00-prior-art.md#ci-caches`.

## Non-goals {#non-goals}

Stated so that scope creep has to argue with something.

- **Not a general build cache.** Depdep covers Elixir dependency builds, `.deb`
  packages and git mirrors. It is not action-level caching for arbitrary work,
  and `spec/00-prior-art.md#bazel` records what is.
- **Not a substitute for Mix's correctness machinery.** Depdep must never serve
  what Mix would not accept. Where a restored unit would be rebuilt by Mix, that
  is a miss and is reported as one — the restore check in `spec/06-the-run.md`.
- **Not a publisher-side distribution mechanism.** Objects are
  consumer-produced, keyed on the whole input closure. The publisher-side
  equivalent already exists and is a different thing:
  `spec/00-prior-art.md#precompiled`.
- **Not a package manager.** Depdep resolves nothing. It reads the lock and asks
  Mix; it never decides which versions a project should have.
- **Not a store administrator.** Reclamation exists and is deliberately narrow
  (`spec/08-reclamation.md`); depdep does not create buckets, manage retention
  policies or hold credentials beyond the run.

## Zero runtime dependencies {#zero-runtime-deps}

Depdep runs **before `mix deps.get`**. A runtime dependency would therefore have
to be fetched by the machinery depdep exists to get in front of, so there is no
ordering in which one could work.

Every entry in the project's `deps/0` is `runtime: false`, and its `only:` is a
subset of `[:dev, :test]`. Nothing else may be added. Such dependencies are not
transitive, so none reaches a project that depends on depdep, and hex leaves
them out of the package's metadata.

A published package of depdep therefore declares no dependencies, whatever
`deps/0` holds for depdep's own development.

```test zero-runtime-deps-guarded
given the project's dependency list
when every entry is examined
then each is runtime: false and only: within [:dev, :test]
and a dependency without both fails the check, naming it
```

## Failure is not an error {#failure-not-error}

The measurement is a by-product of work that has already succeeded, and the store
is an optimisation. Neither may cost a job its result.

`Depdep.Metresis.post/3` returns `:ok`, `:disabled`, `{:warn, message}` or
`{:error, reason}`, and **never raises**. `Depdep.CLI.main/1` warns on the last
two and leaves the exit code alone: a 4xx, a 5xx, a timeout or a refused
connection is a line on stderr and nothing more.

`Depdep.CLI.main/1` exits non-zero for exactly one class of condition — a
malformed invocation, which exits 2. No store failure, no metresis failure and no
unreachable endpoint changes a run's exit code.

> `post/3`'s own `@doc` lists three outcomes and omits `{:warn, message}`, which
> `Depdep.CLI.main/1` handles and which `send_with_profile/4` returns. The code is
> consistent; the docstring is not. Filed as #121 rather than settled here.

```test failure-is-not-an-error
given a metresis instance that refuses the connection
when a run posts its metrics
then the run warns and its exit code is unchanged
```
