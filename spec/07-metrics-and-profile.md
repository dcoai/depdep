# Metrics and the profile

A run measures itself and posts the measurements to a metresis instance, when one
is configured. **Both variables unset means no request is attempted at all**, so a
consumer that ignores this is unaffected and nothing in its pipeline changes.

The numbers are a by-product of work that has already succeeded, which is why
nothing here may change a run's exit code
(`spec/01-goals-and-scope.md#failure-not-error`).

The bucket vocabulary these metrics report is defined in
`spec/06-the-run.md#buckets`.

## What a run measures {#metrics}

`Depdep.Metrics.to_map/3` is the run's measurement. Two kinds of number.

**Per run and per provider** — how long the run took and how much of the lock it
settled: `Depdep.Metrics.bytes/1` for volume,
`Depdep.Metrics.effective_parallelism/1` for how much of the configured
concurrency was actually used, `Depdep.Metrics.saved_total_us/1` for what the
store saved, `Depdep.Metrics.sum_unit_us/1` and `Depdep.Metrics.unit_us/1` for
where the time went, and `Depdep.Metrics.slowest/1` for the outliers worth
looking at.

**Per unit** — one sample each for download, extraction, bytes, compile time and
time saved.

`Depdep.Metrics.write/2` records them for a later push to find.

**A phase that did no work sends no parallelism sample.** An average over a phase
that transferred nothing is not zero parallelism; it is no measurement, and
sending zero would drag every average toward it.

Durations are posted in **seconds**, though they are carried internally in
microseconds.

## The summary line {#summary}

`Depdep.Report.render/2` is what a reader of a pipeline log sees.
`Depdep.Report.buckets/1`, `Depdep.Report.count/3` and
`Depdep.Report.outcome/3` build the tally, `Depdep.Report.duration/1` formats
times, `Depdep.Report.total/1` sums, and `Depdep.Report.merge/1` combines phases.

Each unit appears once, in the bucket the run ended with — the property
`spec/06-the-run.md#second-pass` establishes.

## The profile {#profile}

A **profile** is the document that tells metresis what depdep's metrics mean:
their names, types, units, polarity, guidance prose, and a starter dashboard.
`Depdep.Profile.read/0` reads it, `Depdep.Profile.path/0` locates it, and
`Depdep.Profile.vocabulary/0` lists the names it defines.

`Depdep.Profile.hash/0` is the profile's identity: a SHA-256 over its canonical
JSON encoding. The hash, not the version, is what a post carries — a hash is what
a machine can compare exactly.

`Depdep.Profile.emitted/0` lists the metric names the code actually posts.
`Depdep.Profile.compare/3` compares the shipped document against what an
instance holds, **by vocabulary rather than by hash**, so a difference is
reported as which names are missing on which side rather than as two unequal
hexadecimal strings.

`Depdep.Profile.check/0` and `Depdep.Profile.check/1` hold the document to what
the code emits, **in both directions**: a metric posted but undefined would
register bare on the instance, and a metric defined but never posted is a claim
the code does not make.

> The document's `version` field is **not** currently bumped when the vocabulary
> changes, and an instance takes that version verbatim. Filed as #111. This
> section states the hash as the identity because that is what the handshake
> uses; the version's rules belong to #111 rather than being invented here.

```test profile-holds-the-code
given a metric the code emits and the profile does not define
then the check fails, naming the metric
and the same holds in the other direction
```

## The handshake on ingest {#handshake}

Every post carries the hash of the profile this depdep ships. An instance that
does not hold that profile for this token answers **428**, and depdep publishes
the document with the same token and retries the post **once**.

Two round trips per profile version per instance, ever, and **the emitter keeps
no state**.

Nothing loops. A second 428 of any kind is one warning line and done, and every
outcome but a transport failure is `:ok` or a warning — because the numbers are a
by-product of work that already succeeded.

`Depdep.Metresis.post/2` returns `:ok`, `:disabled`, `{:warn, message}` or
`{:error, reason}`, and never raises. The three 428 kinds are distinguished in
what it warns:

| Instance says | What it means for this run |
|---|---|
| `profile_missing` | publish and retry; if it is still missing, say so and stop |
| `profile_pending` | the profile awaits approval, so samples for **new** metrics are not recorded |
| `profile_rejected` | the profile was refused, with the instance's reason |

**Adoption is never requested.** Adoption changes the domain and belongs to an
administrator; the token's own profile is all this needs.

## The posting contract {#posting}

`Depdep.Metresis.config/0` reads the instance and the token. `DEPDEP_METRESIS` is
the instance URL under a shorter name, and **both names at once is refused**
rather than merged — the same rule as the store's two forms
(`spec/04-store-layout.md#configuration`).

`Depdep.Metresis.idempotency_key/3` derives the key from the **pipeline, job and
direction** rather than generating it at send time, so a runner that retries a
job posts the same key and the instance writes nothing the second time. A
duplicated tally is silently wrong in a way no later inspection can distinguish
from a real one.

Outside CI a run id is added, so the key is always derivable.
`Depdep.Metresis.labels/1` carries what the CI environment provides and
**omits what it does not** rather than filling it with a lie.

`Depdep.Metresis.samples/1` and `Depdep.Metresis.documents/3` build the bodies.
The instance caps a request at 2,000,000 bytes and a rejection loses the **whole**
post, so documents are chunked with a bound well under that cap — a bounded
property rather than a lucky one.

`Depdep.Metresis.http_options/0` gives this its **own** timeouts, deliberately
not the store's. The store allows 300 s because it moves large objects;
inheriting that here would let an unresponsive instance add five minutes to every
job in every consumer, which is the opposite of logging and continuing.

```test metresis-idempotency-key
given the same pipeline, job and direction
then the idempotency key is the same across runs
and changing the direction or the chunk changes it
```
