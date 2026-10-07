# Reclaiming the store

*Part of [depdep's guide](../README.md#the-guide). Back to the [README](../README.md).*

The store is append-only: pipelines can read and write, and nothing they run can
delete. That is deliberate — an identity that cannot delete is one that cannot be
talked into wiping your store — and it means the store only grows.

Growth is per *generation*, not per pipeline. One Elixir or OTP bump changes
every key at a stroke; a dependency bump orphans that package and everything
above it; and a git mirror is stored per repository per month whether or not
anything changed.

## What is still needed

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

## Removing it

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
| the schema prefix (mix), `src/v1/` | what no current root names | churn-driven, and the live set is exactly known |
| a retired schema | everything, without consulting the live set | nothing depdep runs can request it, so a root naming one was written by a version nobody runs |
| `git/v1/` | newest `--keep-epochs` per repository (default 2) | a mirror is a seed; an older one is superseded, not unreachable |
| `apt/v1/` | never | small, near-static, shared by every consumer, and its live set needs apt in the right container |
| `roots/` | older than `--within` (default 30 days) | they only accumulate when a branch dies |
