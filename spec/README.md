# depdep's specification

This directory is depdep's specification, and it is normative. Where it and the
code disagree, that is a defect in one of them and an issue gets filed — not a
thing to be quietly settled in either direction.

The README at the repository root keeps its own job: getting a reader started,
and saying why the design is what it is. It is documentation. This is the
contract.

## Why depdep needs one

The store's object key format is a contract between every producer and every
consumer of a store. A schema bump changes every object path and refills every
consumer's store once. Seven projects depend on that format being what it says
it is, and until #112 it was written down nowhere — it lived in moduledocs and a
grep pattern in CI.

## How it is organised

One numbered file per subject, `NN-name.md`:

| File | Subject |
|---|---|
| `00-prior-art.md` | what overlaps with depdep, and where depdep sits |
| `01-goals-and-scope.md` | the problem, the non-goals, the hard constraints |
| `02-architecture.md` | the modules, and how a run moves through them |
| `03-keys.md` | the key: schema version, the recursion, its inputs |
| `04-store-layout.md` | object naming, the S3 surface, configuration |
| `05-units-and-providers.md` | units, and the `mix`, `apt` and `git` providers |
| `06-the-run.md` | the two passes, restoring, and `--compile-deps` |
| `07-metrics-and-profile.md` | the metric vocabulary and the metresis contract |
| `08-reclamation.md` | sweeping, grace, and the safety rules |
| `09-cli.md` | flags, precedence, exit codes |
| `10-decisions.md` | the decisions log |

**The numbers are append-only. Never renumber a file.** A section's id is its
file and the path of headings down to it — `spec/03-keys.md#schema` — so
renaming a file orphans every relation in it. A new subject takes the next
number even when a lower one would read better in a table of contents. This is
the same hazard `guides/writing-specs.md` §3 raises about numbers inside
headings, and it applies to filenames for exactly the same reason.

## How to write in it

`guides/writing-specs.md` in surfex is the guide, and it is worth reading before
adding a section. The essentials:

- **One requirement per section**, or mark each requirement with
  `<!-- surfex: id -->` when a heading each would be too many headings. Two
  requirements sharing a section share a version, so editing either dangles the
  relations of both.
- **Overviews and rationale go in a parent's body**, apart from the
  requirements, so rewording a rationale dangles nothing that relates to a rule.
- **Headings are names, not summaries**, and anything related to carries an
  anchor: `## The schema version {#schema}`. "Sending" survives rewording;
  "messages are queued, never sent synchronously" does not.
- **Name the code in the section that describes it**, in full and in backticks —
  `` `Depdep.Key.compute/3` ``, not "compute". That is what lets
  `mix surfex.suggest` relate a section to what implements it.
- **State requirements as checkable claims**: what is returned, what is
  rejected, what stays unchanged. A claim nobody can check cannot dangle
  usefully either.
- **Give examples for concrete behaviour and invariants for rules over all
  inputs**, and a `test` hint where how to check something is not obvious.

## How it is held to the code

Every section that describes code is related to that code, and the relation
records the versions both ends had when somebody confirmed them. Change either
end and the relation **dangles** until someone reads both and confirms it again.

```sh
mix surfex.suggest          # what the spec's own citations imply
mix surfex.suggest --accept # record those relations
mix surfex.status           # what still needs a judgement
mix surfex.confirm <id> --note "read both ends"
mix surfex.goldens --write  # regenerate RELATIONS.md
```

`mix surfex.status` runs in CI, and `RELATIONS.md` is the committed record of
where every relation stands.

**Confirming is a claim that someone read both ends in the same turn.** It is
per-id and takes a `--note` saying so. There is no bulk accept, deliberately: a
log of confirmations nobody read is worth less than no log at all.

`RELATIONS.md` is a whole-file generated artifact. On a merge conflict, take
both sides' *source* changes and regenerate it with `mix surfex.goldens --write`
— never hand-merge its rows.

## The gate arrives in stages

`.surfex.exs` carries no `require:` and no `triangle:` yet, and #120 adds both.
Turning them on before the spec has content would fail the check for all thirty
modules from the first commit and keep failing for the length of the effort,
which is how a gate teaches people to ignore it. Each work item under
#112 leaves CI green, and the gate tightens when there is something for it to
hold.
