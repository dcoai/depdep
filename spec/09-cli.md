# The command line

Depdep is one executable with one invocation per run. Everything a consumer does
with it is a combination of the switches below, and every switch is listed here —
a switch the code accepts and this file omits is a defect in one of them.

What each mode *does* is specified elsewhere: the run in `spec/06-the-run.md`,
reclamation in `spec/08-reclamation.md`. This file specifies the **surface**.

## Modes {#modes}

One mode per run.

| Switch | What it does |
|---|---|
| `--plan` | computed keys, no network |
| `--report` | what the store holds, and how much is still reachable |
| `--sweep` | remove what no current root needs; operator only, dry run unless `--confirm` |
| `--pull` | restore what the store has |
| `--push` | upload what it does not |
| `--help` | the usage text |

`--provider NAME` selects the artifact kind and is repeatable; the default is
`mix` (`spec/05-units-and-providers.md#contract`).

## Every switch {#switches}

| Switch | Type | Applies to | Default |
|---|---|---|---|
| `--plan` `--report` `--sweep` `--pull` `--push` `--help` | flag | — | — |
| `--mix-get` | flag | `--pull` | off |
| `--compile-deps` | flag | `--pull --mix-get` | off |
| `--provider NAME` | repeatable | all | `mix` |
| `--project DIR` | repeatable | mix | discovery (`spec/04-store-layout.md#layout`) |
| `--exclude PREFIX` | repeatable | mix | none |
| `--env ENV` | string | mix | `test` |
| `--within DAYS` | integer | `--report` `--sweep` | 30 |
| `--confirm` | flag | `--sweep` | off |
| `--grace DAYS` | integer | `--sweep` | 2 |
| `--keep-epochs N` | integer | `--sweep` | 2 |
| `--consumer NAME` | string | `--pull` | `$CI_PROJECT_PATH`, else the checkout qualified by host |
| `--ref NAME` | string | `--pull` | `$CI_COMMIT_REF_SLUG` |
| `--package NAME` | repeatable | apt | — (required for `--pull`) |
| `--apt-cache-dir DIR` | string | apt | `/var/cache/apt/archives` |
| `--repo URL` | repeatable | git | — |
| `--git-mirror-dir DIR` | string | git | `.depdep/git` |
| `--metrics PATH` | string | all | — |

```test cli-switches-documented
given the switches the parser accepts
then every one appears in the usage text
and every switch the usage text names is accepted
```

## How a bad invocation is answered {#parsing}

`Depdep.CLI.parse/1` is strict.

**Every problem is reported, not only the first.** A reader fixing an invocation
should see all of it.

**An unknown switch is named, and a malformed value says the VALUE was wrong
rather than the name.** `OptionParser` reports both the same way, so the name is
checked against the known set — a reader whose value is missing should not go
looking for a typo.

**A switch this version does not have yet is refused like any other.** Silently
dropping an unrecognised switch is how one consumer lost an afternoon: a
`--provider apt` against a build that predated providers was dropped, the mix
provider ran instead, and the run died evaluating `config/config.exs`, which reads
as a configuration bug.

**Failing here is safe because an unknown switch cannot arrive on its own.**
Someone has to edit the invocation, so this can never break a pipeline that was
working — only one that has just been changed, which is when being stopped is
useful.

## Which combinations are legal {#combinations}

`Depdep.CLI.combination/2` decides.

| Invocation | Answer |
|---|---|
| `--compile-deps` without `--mix-get` | refused: it compiles what a pull left missing *after* `--mix-get` |
| `--mix-get` without `--pull` | refused: it runs `mix deps.get` inside a pull |
| `--mix-get` with a provider other than mix | refused: it is for the mix provider only |
| `--pull --mix-get`, default provider | allowed |
| anything without `--mix-get` | allowed |

## The hint after a usage error {#hints}

`Depdep.CLI.hint/1` chooses one sentence by **what** went wrong, not by which
branch caught it.

There used to be a single sentence for the whole branch, written when every error
in it was a switch error. A later change routed `DEPDEP_ENABLED` through the same
branch and the sentence was reused unread, so a reader whose *environment
variable* was refused was told the problem was a switch.

A third error class added later must choose its own sentence here rather than
inherit one.

## The off switch {#off-switch}

`DEPDEP_ENABLED=false` turns depdep off: it reports that it is off and exits 0
without reading anything. **Unset means enabled**, so leaving it alone is the same
as never having heard of depdep.

`Depdep.CLI.enabled?/0` reads it. `true` and `false` are accepted whatever their
case or spacing, empty reads as unset like every other `DEPDEP_` variable, and
**a value it cannot read is refused rather than guessed at** — the error names the
value and what would be accepted. A typo must not silently mean one of the two.

That line is not a warning. Nothing went wrong, and the line *is* the run's
summary, so it goes where the summary goes.

## Exit codes {#exit-codes}

| Code | When |
|---|---|
| 0 | the run finished, including when the store was unreachable or unset |
| 0 | `DEPDEP_ENABLED=false` |
| 2 | a malformed invocation — an unknown switch, a bad value, an illegal combination, an unreadable `DEPDEP_ENABLED` |
| Mix's status | a dependency failed to compile under `--compile-deps` (`spec/06-the-run.md#compile-failure`) |

There is no other non-zero exit. The reasoning is
`spec/01-goals-and-scope.md#failure-not-error`.

## The profile task {#profile-task}

`Mix.Tasks.Depdep.Profile` is a separate surface, for holding the metric
vocabulary honest rather than for moving artifacts.

`mix depdep.profile check` compares the shipped document against what the code
emits, both ways. `mix depdep.profile check --instance` additionally compares it
against what a configured instance holds — advisory, because it depends on
reaching that instance (`spec/07-metrics-and-profile.md#profile`).
