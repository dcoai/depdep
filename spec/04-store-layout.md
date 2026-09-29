# The store, and what depdep operates on

A store is an S3-compatible bucket holding immutable objects named by key
(`spec/03-keys.md#object-path`). Depdep reads and writes it with a small,
deliberate subset of the S3 API, and nothing else in depdep knows it is S3.

The store is an optimisation. Every failure to reach it is reported and the run
continues — `spec/01-goals-and-scope.md#failure-not-error`.

## Where a store is {#configuration}

`Depdep.S3.config/0` answers where the store is, or why it cannot be reached.
There are two forms and **only one may be present**:

```
DEPDEP_STORE=s3://ACCESS_KEY@host:9000/bucket?region=us-east-1
DEPDEP_SECRET_KEY=…
```

or the four `DEPDEP_ENDPOINT`, `DEPDEP_BUCKET`, `DEPDEP_ACCESS_KEY` and
`DEPDEP_REGION` beside the same `DEPDEP_SECRET_KEY`.
`Depdep.S3.store_url/1` parses the URL form.

**The secret is never in the URL, and a URL carrying one is refused.** A URL
reaches shell history; a masked CI variable does not. The URL carries the shape
of the store and the access key only.

`s3` is a plain-HTTP endpoint, as `DEPDEP_ENDPOINT` is usually written;
`s3+https` and `https` are TLS.

**Both forms at once is refused rather than merged**, for the same reason a typo
in `DEPDEP_ENABLED` is: a half-edited configuration must be loud. An empty value
reads as unset, as every `DEPDEP_` variable does.

`{:error, reason}` from `Depdep.S3.config/0` is not a failure. The caller reports
it and runs without a store.

```test store-config-one-form
given both DEPDEP_STORE and the separate variables
then configuration is refused, naming the conflict
and neither form is silently preferred
```

## How many transfers run at once {#concurrency}

`Depdep.S3.concurrency/0` derives the limit; `Depdep.S3.concurrency_setting/0`
reports what is in force and where it came from.

The work is IO-bound — a round trip plus a tar extraction — so the derived value
is a multiple of the scheduler count rather than equal to it, clamped so that a
two-core laptop still overlaps usefully and a 96-core runner does not open
ninety-six sessions against one store.

`DEPDEP_CONCURRENCY` overrides it. **It is an instrument, not a tuning knob**: it
exists so that `DEPDEP_CONCURRENCY=1` is a serial baseline against the same
commit and the same objects, with one variable moved. If a measurement shows the
derivation is wrong, the derivation is what changes.

**The derived clamp does not apply to an explicit value.** Putting `1` through a
`max(8)` would run eight transfers and report the run as serial — exactly the
quietly-wrong number the variable exists to prevent.

## The S3 surface depdep uses {#s3}

Requests are signed with AWS Signature v4, written out rather than taken from a
library (`spec/01-goals-and-scope.md#zero-runtime-deps`).

| Function | What it does |
|---|---|
| `Depdep.S3.head/2` | `:hit`, `:miss` or `{:error, reason}` — never a raise, so a flaky store degrades to a compile |
| `Depdep.S3.get/3` | streams to a destination path, so a large object never sits in memory |
| `Depdep.S3.put/4` | uploads with optional metadata |
| `Depdep.S3.metadata/2` | reads an object's metadata without its body |
| `Depdep.S3.list/2` | lists a prefix, following continuation tokens |
| `Depdep.S3.delete/2` | removes one object; reclamation only |

`Depdep.S3.delete/2` is the one destructive call, and a pipeline identity should
not hold the credential that can make it — see `spec/08-reclamation.md`.

A listing is paged. `Depdep.S3.list/2` follows the continuation token until the
listing is complete, so a caller never sees a truncated set and mistakes it for
the whole store.

`Depdep.S3.encode_path/1` and `Depdep.S3.canonical_query/1` are the two places
signing is easy to get subtly wrong: a key holding a reserved character must be
encoded the same way in the path and in the signature, and query parameters must
be canonically ordered. A mismatch is a 403 on exactly the keys that contain the
awkward character, which is how it escapes notice.

```test s3-reserved-characters
given an object key containing a reserved character
when it is signed and requested
then the request is authorised rather than answered 403
```

## Compile-time configuration {#compile-config}

`Depdep.Config.read/3` returns `%{app_string => digest}` for a project.

**Only `config/config.exs` and the files it imports are compile-time.**
`config/runtime.exs` is by definition not, and is never read.

**The slice is per application, and that is what keeps objects shareable.** A
project-wide digest would differ for every consumer, so no two would share an
object and the store would hold one object per consumer per dependency — saving
nothing. What the digest is *for* is `spec/03-keys.md#config`.

A project with no `config/` at all yields an empty map rather than an error. No
compile-time configuration is an ordinary state, and every app then digests as
the empty list.

Configuration is evaluated with the member's `mix.exs` loaded, so a config that
calls into its own project module, or asks `Mix.Project` for the build path, sees
the member's answers rather than the current directory's.

**One caveat a consumer must check in its own project.** This assumes no value
under a *dependency's* app is derived from the environment. If `config :some_dep`
reads `System.get_env/1`, that dependency's digest becomes machine-dependent and
its objects stop being portable between a developer's machine and CI. Values
under the consumer's own apps may do as they like — they are not part of any
dependency's key.

## Which projects depdep operates on {#layout}

`Depdep.Layout.projects/2` resolves the members, in this order, so the common
cases need no configuration:

1. **Explicitly named.** `--project DIR`, repeatable. Always wins.
2. **A poncho.** Every `mix.exs` beneath the root is a member. The root having a
   `mix.exs` of its own does not preclude this: a poncho with a root coordinator
   is an ordinary shape, and the root joins its members rather than replacing
   them.
3. **A single Mix project.** The root has a `mix.exs` and nothing beneath it.

Two things are never members:

- Anything under `deps/` or `_build/`. A dependency's own `mix.exs` is not a
  member.
- **A directory with a `mix.exs` but no `mix.lock`.** Without a lock there is
  nothing to key, so such a directory has no objects either way. This keeps a
  fixture or a vendored project from becoming a phantom member, and in a real
  poncho it separates buildable members from path dependencies that only a
  parent ever compiles. Measured on one poncho: 52 `mix.exs`, 38 `mix.lock`.

  **This rule applies to discovered members, not to case 3.** A root somebody
  pointed depdep at is not a guess, so a single project without a lock is still
  that project.

  The count dropped this way is reported **once per run**, never once per
  directory. Fourteen identical lines is noise, and noise that repeats is noise
  that gets filtered.

`--exclude PREFIX` drops a member and everything beneath it, matched on
**segment boundaries**: `--exclude tools` drops `tools/cli` and leaves
`tools_vendor/x` alone. A prefix may go as deep as it needs to, because a
toolchain varies per member rather than per top-level group.

Notes are returned rather than printed, so IO stays in the CLI.

```test layout-segment-boundaries
given members tools/cli and tools_vendor/x
when --exclude tools is given
then tools/cli is dropped and tools_vendor/x is kept
```
