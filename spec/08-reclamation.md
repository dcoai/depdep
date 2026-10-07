# Reclamation

A store grows. Reclamation is the operator command that removes what nothing needs
any more, and it is deliberately narrow.

`Depdep.Sweep.plan/3` is the whole decision. It is **pure**: handed a listing, a
live set and the clock, it answers what to delete. Everything that talks to a
store stays in the CLI, so the part worth being sure about is exercised without
one.

## A wrong deletion is costly, never corrupting {#cost-not-corruption}

This is what justifies the whole approach, and most garbage collectors cannot say
it.

Delete something still needed and the next pipeline misses it, recompiles it and
pushes it back. So the rules can be decided on **cost** rather than on fear, and
an incomplete run degrades instead of breaking.

It is still a cost, which is why the three rails below exist.

## Three rails {#rails}

`Depdep.CLI.Operator.sweep/1` refuses to remove anything unless all three hold.

- **Nothing is deleted without `--confirm`.** A `--sweep` without it is a dry
  run: it says exactly what it would remove and removes nothing. There is no
  `--dry-run` switch, and none is wanted — the safe behaviour is the default, so
  the destructive act is the one that has to be spelled out.
- **`--grace DAYS`** (default 2) never touches anything **less than `DAYS` old**, so a
  push racing a listing is not swept. The boundary is exclusive, so `--grace 0` protects
  nothing — which is what it reads like, and was not always true (`#warts`). The same
  comparison answers `--within`, so "within N days" means strictly less than N days old
  throughout.

```test grace-zero-protects-nothing
given an object written seconds ago
then --grace 0 does not protect it and --grace 1 does
and an object exactly DAYS old is not protected
```
- **No current roots means no sweep.** A store nobody uses and a misconfigured
  invocation look identical from the outside, and one of them would delete
  everything. `Depdep.Sweep.current_roots` decides, and refuses with a reason;
  the CLI adds that `--report` is where to look first. An unreadable timestamp
  counts as **current** here, the same fail-safe direction `#prefixes` states —
  an unreadable age must not silently shrink the live set, because a shrunken
  live set means over-deletion.

The third is the one that matters most, because it is the only one that protects
against the operator being wrong rather than against the clock.

**The real guard is the credential, not the flag.** `Depdep.S3.delete/2` is the
only destructive call depdep makes, and a pipeline identity should not hold a
credential that can make it (`spec/04-store-layout.md#s3`).

```test sweep-refuses-without-roots
given a listing and no current roots
then nothing is swept, and the refusal says to look at --report
```

Met by #126, which also moved the decision out of the CLI and into
`Depdep.Sweep` so it could be tested at all. `--report` now counts a current root
by the same function, because a report that disagreed with the sweep it precedes
would be worse than no report.

## Aiming a sweep {#aim}

The three rails above decide **what** a sweep removes. None decides **where** it
acts, and that is a separate way to be wrong: the store comes from the
environment, so an inherited variable can aim a correct command at the wrong
bucket.

So **`--confirm` must name the bucket it will change.** `--bucket NAME` is
required with `--confirm` and refused unless it is the configured bucket. The
check happens before the listing, so a misaimed invocation costs nothing and says
so immediately. A dry run needs nothing — it changes nothing, and making the safe
path harder would push an operator toward the destructive one.

**The real guard is still the credential, and that is now measured rather than
recommended.** A pipeline identity does not hold a credential that can delete at
all. Verified against the production store without removing anything, by asking it
to delete a key that cannot exist — S3's DELETE is idempotent, so the request
tests permission and nothing else:

```
DELETE __depdep_permission_probe_… → 403 AccessDenied (elixir-dep-store)
```

Repeat that whenever the claim needs re-checking. This rail exists for the
operator who legitimately *does* hold a deleting credential, which is the one case
the credential cannot cover.

```test sweep-confirm-names-its-bucket
given --confirm naming a bucket that is not the configured one
then nothing is listed or removed, and the refusal shows both names
```

## One rule per prefix, because the providers are not alike {#prefixes}

`Depdep.Sweep.plan/3` matches the known provider prefixes and treats
**everything else** as a mix object. That fallback is deliberate, not incidental:
it is what makes reclamation independent of the key's schema version, so raising
the schema (`spec/03-keys.md#schema`) cannot quietly stop objects being reclaimed.

| Prefix | Rule | Why |
|---|---|---|
| a **retired** schema (`Depdep.Key.retired/0`) | removed, **without consulting the live set** | `Depdep.Key.object/3` builds every path from the *current* schema, so no running depdep can request one — it is unreachable by construction, and a root naming it was written by a version nobody runs |
| anything not below (mix) | mark and sweep against the live set | churn-driven growth, and the live set is exactly known from the roots consumers write |
| `git/` | keep the newest `--keep-epochs` per repository (default 2) | a mirror is a *seed* whose staleness is harmless by construction, so an older epoch is **superseded** rather than unreachable |
| `apt/` | never | small, near-static, shared by every consumer and image; its reachable set needs apt in the right container to compute — little to reclaim, more to get wrong |
| `roots/` | older than `--within` (default 30 days) | they overwrite per consumer, ref and provider, so they accumulate only when a branch dies |

A git dependency's **source** (`src/`, `spec/03-keys.md#source-key`) takes that
fallback deliberately: every unit's object goes into the root its consumer writes on
each pull, so a source object's reachable set *is* exactly known — which is the one
thing that is not true of apt. A source nobody wants any more ages out with the
consumers that stopped wanting it, and no rule of its own is needed.

Its growth is also the gentlest shape here: **one object per git dependency per locked
commit, changing only when the lock does.** A mirror's monthly epoch accumulates whether
or not anything changed; a source does not.

```test source-objects-are-reclaimed-by-reachability
given a source object no current root names
then it is swept, and one a current root names is kept
```

`Depdep.Sweep.protected/2` counts what the grace period is currently holding, so
a report can say why an object a human expected to go is still there.

**Marking would be the wrong rule for mirrors.** It would keep every epoch any
consumer ever pulled, forever. Age is the truer rule there precisely because
staleness costs a larger delta and nothing else (`spec/05-units-and-providers.md#git`).

**Marking cannot retire a schema, which is why the first rule exists.** A root is
overwritten per consumer, ref and provider, so a branch that has not built since its
consumer's pin moved never refreshes its own — and keeps naming the old prefix
indefinitely. Measured before the rule: 382 of the production store's 570 `v2` objects
were "reachable" that way, none of them requestable. The grace window still applies to a
retired object, because a push racing a listing does not care which schema it is.

**The report and the sweep classify a key with one function**, `Depdep.Sweep.rule_for/1`,
whose mix case is the **fall-through** — "not one of the named prefixes" rather than any
particular schema spelling. That is why the `v2` → `v3` bump did not break reclamation, and
it is what keeps `--report` and `--sweep` from disagreeing about what a key is: the command
read before deleting and the delete answer the same question once. A source checkout is
named separately (`:source`) although the sweep decides it exactly as mix, because `src/v1`
is not a schema and the report says more by keeping it.

```test one-classification-for-report-and-sweep
given a listing holding every prefix at the current schema
then the report shows one group per prefix, not one per package
and the schema prefix is the fall-through, so a bump cannot split it
```

**Adding a schema to that list would delete live objects**, which is the one way
reclamation here can cause real loss rather than a recompile. It is as deliberate an act
as changing the current schema, and a test asserts the current one is never in it.

```test retired-schema-is-swept-regardless-of-roots
given an object under a retired schema that a current root names
then it is swept, with the schema in the reason
and a current-schema object is still decided by reachability
```

An unparseable timestamp is treated as **recent**, not as ancient. The
conservative direction costs a delayed deletion; the other loses an object that
was still wanted.

## What the live set is {#live-set}

The live set is the union of the object paths named by the roots consumers wrote
on their last pull — `spec/06-the-run.md#roots`.

A root nobody has refreshed within `--within` is itself swept, which keeps the
thing that solves unbounded growth from growing unboundedly.

## What `--report` answers {#report}

`Depdep.CLI.Operator.report/1` says what the store holds and how much of it is
still reachable, grouped by prefix. It deletes nothing and needs no credential
beyond the one a pipeline already has.

**It counts a current root by the same function the sweep does**
(`Depdep.Sweep.current_roots/2`), so the two cannot disagree. A report that said a
root was current while the sweep thought otherwise would be worse than no report,
because it is the command an operator reads *before* deleting.

**A retired schema's group is reported as reclaimable, with no reachable count.**
Counting reachability there would be reporting a number with no meaning: nothing
depdep runs can request the object (`#prefixes`), so a root naming one was written by
a version nobody runs. The production report said `382 reachable` of 570 `v2` objects,
which invited reading 1.2 GiB of dead weight as storage still in use — exactly
backwards in the command an operator reads *before* deleting.

A store it cannot reach, or one with no credentials, is reported as such and exits
0 — the same rule as everywhere else (`spec/01-goals-and-scope.md#failure-not-error`).

```test report-marks-a-retired-schema-reclaimable
given a store holding an object under a retired schema
then --report marks the group retired and prints no reachable count for it
and a current-schema group still reports its reachable count
```

## Two known warts {#warts}

Recorded rather than specified away, because writing down a defect as though it
were intended is how it becomes permanent.

**The grace window's boundary — fixed in #108/#170.** `--grace` was applied per whole day
and **inclusively**, so `--grace 0` protected everything rather than nothing, and `-1` was
the only value that protected nothing. The comparison is strict now and the rule is stated
where the flag is (above): within N days means strictly less than N days old.

Recorded rather than deleted, because *how* it survived is the reusable part. The suite
passed ages in whole days and never 0, so nothing ever asked the boundary question; and the
one job that would have shown it had to pass `--grace -1` to work at all, **with a paragraph
explaining the minus sign** — the defect was documented as a workaround instead of being
filed, for a while. That job is the regression test now: at `--grace 0` it sweeps, and an
inclusive boundary would make it delete nothing and fail.

**`--report` grouped mix objects one row per package — fixed in #125/#169.**
`report/1` classified by a literal `v2` prefix, which stopped matching under `v3`,
so the production store printed 128 groups instead of one. It now groups by
`Depdep.Sweep.rule_for/1`, the same classification the sweep itself dispatches on,
whose mix case is the **fall-through** — so there is no schema literal left to go
stale at the next bump. Recorded here rather than deleted: the defect reached
production because `--report` is run by hand and nothing in CI grouped a listing.
