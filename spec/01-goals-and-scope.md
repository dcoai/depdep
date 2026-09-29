# Goals and scope

Depdep restores compiled build artifacts — Elixir dependencies, distribution
packages and git mirrors — from a content-addressed store, so a CI job does not
rebuild what some earlier job already built.

This file states the two constraints that shape everything else. The problem
statement, the non-goals and the rest of the scope arrive with #114; the two
requirements below are here because #113 is the change that makes one of them
enforceable.

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
