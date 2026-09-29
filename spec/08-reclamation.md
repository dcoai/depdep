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
- **`--grace DAYS`** (default 2) never touches anything created that recently, so
  a push racing a listing is not swept.
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

## One rule per prefix, because the providers are not alike {#prefixes}

`Depdep.Sweep.plan/3` matches the known provider prefixes and treats
**everything else** as a mix object. That fallback is deliberate, not incidental:
it is what makes reclamation independent of the key's schema version, so raising
the schema (`spec/03-keys.md#schema`) cannot quietly stop objects being reclaimed.

| Prefix | Rule | Why |
|---|---|---|
| anything not below (mix) | mark and sweep against the live set | churn-driven growth, and the live set is exactly known from the roots consumers write |
| `git/` | keep the newest `--keep-epochs` per repository (default 2) | a mirror is a *seed* whose staleness is harmless by construction, so an older epoch is **superseded** rather than unreachable |
| `apt/` | never | small, near-static, shared by every consumer and image; its reachable set needs apt in the right container to compute — little to reclaim, more to get wrong |
| `roots/` | older than `--within` (default 30 days) | they overwrite per consumer, ref and provider, so they accumulate only when a branch dies |

`Depdep.Sweep.protected/2` counts what the grace period is currently holding, so
a report can say why an object a human expected to go is still there.

**Marking would be the wrong rule for mirrors.** It would keep every epoch any
consumer ever pulled, forever. Age is the truer rule there precisely because
staleness costs a larger delta and nothing else (`spec/05-units-and-providers.md#git`).

An unparseable timestamp is treated as **recent**, not as ancient. The
conservative direction costs a delayed deletion; the other loses an object that
was still wanted.

## What the live set is {#live-set}

The live set is the union of the object paths named by the roots consumers wrote
on their last pull — `spec/06-the-run.md#roots`.

A root nobody has refreshed within `--within` is itself swept, which keeps the
thing that solves unbounded growth from growing unboundedly.

## Two known warts {#warts}

Recorded rather than specified away, because writing down a defect as though it
were intended is how it becomes permanent.

**The grace window's boundary.** `--grace` is applied per whole day and
inclusively, so `--grace 0` protects everything rather than nothing. Filed as
**#108**. This section does not state the boundary as intended behaviour; the
intended semantics are that issue's to settle.

**`--report` groups mix objects one row per package.**
`Depdep.CLI.Operator.report/1` classifies by a literal `v2` prefix, which no
longer matches under schema `v3`, so a store with 113 packages prints 113 groups
instead of one. Filed as **#125**. Deletion is unaffected — `Depdep.Sweep.plan/3`
uses the fallback described in `#prefixes` — so this is a readability defect in
the command an operator runs *before* deleting.
