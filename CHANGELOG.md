# Changelog

What changed for a user of depdep, per release. Each version is a git tag;
the four earliest also carry GitLab release notes, from which these entries
are condensed. Issue numbers are dco-tek/depdep's.

## v0.11.0 — 2026-10-08

**No refill, no re-push for existing objects:** keys are unchanged and the schema stays `v3`.
A git dependency's **source** is a new kind of object (`src/v1/`), so the first run after
pinning pushes those; everything already in the store stays usable.

### Added

**A git dependency's source is restored, so `deps.get` does not clone it** (#163, #164,
#165). Depdep already restored a git dependency's *build*; the checkout itself still came
from a clone on every cold run. The source is keyed on the normalised repository and the
locked commit — no content hash, because the commit **is** the content address — and
restored in the first pass, before `mix deps.get` runs. On a warm run measured against
extc that was about 35 seconds of a 52-second run.

Two hazards worth knowing, both guarded: a source unit is never handed to
`mix deps.compile` (it is not something Mix can compile, and `--compile-deps` makes Mix's
status the run's), and a checkout at the wrong commit is a **miss**, not a hit.

### Fixed

**A correct restore is no longer refused when the member's config sets a compile-time
value** (#161). This is the one most consumers were waiting for. A dependency's status
depends on the application environment: `Config.Provider.valid_compile_env?/1` compares
what a dependency recorded at build time against `Application.fetch_env` **in the asking
VM** — and nothing had put the member's config there. So any dependency recording a value
the consumer sets to a non-default read as `:envoutdated`, and a perfectly good object was
refused, every run. The object in the store was never wrong.

**`--explain-rebuilt` names the differing compile-env entry and both values** (#162), so
`compile env: {:app, :key} was true, is false` replaces a shrug.

**A flat key cannot collide** (#157) — asserted rather than assumed, which is what the
recursive key exists to prevent.

### Changed — operators

**`--grace 0` protects nothing** (#170). It used to protect everything written in the last
24 hours: the comparison was inclusive over whole days, so `-1` was the only value that
protected nothing. `--grace N` now means *strictly less than N days old* throughout, which
also moves `--within`'s boundary by the same rule. If you pass `--grace -1` anywhere, use
`0`.

**`--report` prints one row per schema again** (#169/#125), instead of one row per package.
The grouping broke silently at the `v3` bump and is now taken from the sweep's own
classification, so the two cannot disagree and a later bump cannot split it.

**A retired schema's objects are swept without consulting the live set** (#166/#167).
Retiring a schema was only half possible: writing under a new prefix was easy, removing the
old one was not, because stale roots still named it. `Depdep.Key.retired/0` names the
retired schemas and reclamation removes their objects outright — nothing depdep runs can
request one. `--report` shows such a group as reclaimable rather than claiming it is live.

### Changed — metrics

**The profile is version 3** (#171/#111). It had stayed at 1 through five new metrics and
three new panels, and an instance takes the version verbatim, so updates announced nothing.
The version is now bound to the document by a content hash and a committed golden, failing
in both directions: content that moved without a bump, and a bump that announces nothing.
An instance will offer the newer vocabulary once it receives this document.

### Documentation

The README is an introduction again, with the detail moved verbatim into `guide/`
(#146/#147). `guide/01-getting-started.md` now states what a store must **do** — the S3
object API, Signature v4, ListObjectsV2 with continuation tokens — rather than naming a
product, and separates stores depdep has been run against from stores that should work
(#182/#107). MinIO is no longer obtainable; SeaweedFS is exercised by depdep's own CI on
every pipeline, including a check that a wrong secret is refused.

`Depdep.Metresis.post/3` documents all four of its outcomes (#181/#121); it had omitted
`{:warn, message}`.

### Internal

A fourth reclamation rail — `--confirm` must name the bucket it is aimed at (#150). Spec
and relation work: #153, #154, #158, #159. depdep's own CI no longer inherits the group's
store variables (#149). Dev-time dependency `surfex` moved to 0.6.1 (#183).

## v0.10.0 — 2026-10-06

**No object path changes, so no refill.** Keys are unchanged; schema stays `v3`.
As with v0.9.0, objects already in the store become usable rather than needing a
re-push.

One fix, and it is the **second** cause of the same symptom v0.9.0 addressed. If a
project still sees `restored, but Mix would rebuild it` on a **git** dependency
after pinning v0.9.0, this is why.

### Fixed

- **A restored git dependency adopts the restoring project's `origin`** (#144, for
  #123). An object's git checkout carries the *pusher's* `origin`, and Mix compares
  it: `Mix.SCM.Git.lock_status/1` requires the lock's URL to equal
  `remote.origin.url` **as strings**. So a consumer that writes
  `https://host/org/dep.git` where the pusher wrote `git@host:org/dep.git` was told
  the dependency was out of date — the same sentence Mix uses for a genuine lock
  difference, which is why this and #131 were one symptom with two causes.

  The URL stays out of the key: for a git entry the commit sha is the content
  identity, so one object serves every spelling rather than storing the same commit
  once per way of writing its address. The address is corrected on the way in
  instead.

  Measured in the production store, not inferred: `extla`'s objects for one commit
  exist under both `git@…:dco-tek/extla.git` and `https://…/dco-tek/extla.git`,
  while `extc` locks the https spelling and `visualize`, `visualize2` and `exio`
  lock the ssh one.

  Fail-safe, as everywhere else: if the rewrite cannot be done the unit becomes a
  miss and is compiled. A checkout with no `.git` is left alone and the restore
  check turns Mix's rebuild into a miss with Mix's own reason. A hex dependency
  runs no git command.

### Documentation

- **The README's Status section reads as the fleet measures** (#143, for #142). It
  led with the best result ever recorded — `~28 minutes to 6m24s`, labelled
  *Measured* — with nothing beside it to calibrate against. That figure is true of
  the poncho depdep was extracted from and is kept, now labelled a **ceiling**,
  with the current per-consumer net beside it as the expectation: **+8 s to +126 s**
  per pipeline. Current refused-restore counts replace "with zero dependencies
  recompiled", and the `564 byte-identical keys` sentence says what it actually
  showed — that extracting depdep changed no key — rather than vouching for rules
  that have since moved to schema `v3`. Every figure carries its date and how to
  re-take it.

- **The production `--report` is recorded** (#41, closing a check left open since
  v0.1.0). `--report` had never run against a real bucket; it has now. 922 roots,
  `apt/v1` 269 objects / 211.1 MiB, `v2` 569 objects / 1229.4 MiB with **451.9 MiB
  unreachable** — the largest reclaimable thing in the store, waiting on consumers
  leaving v0.6.0 (#140). With the concurrency A/B and the standing apt round-trip
  job, all three claims that shipped unverified are now measured.

## v0.9.0 — 2026-10-04

**No object path changes, so no refill.** Keys are unchanged; schema stays `v3`.
Objects already in the store become usable again rather than needing a re-push.

One fix, and it is the one seven consumers have been waiting on. If a project
sees `restored, but Mix would rebuild it` on warm runs, this is very likely why.

### Fixed

- **A restore lands where *this* member builds** (#131, the mechanism behind #122
  and #110). An object's entry names carry the pusher's `build_path`: metresis
  compiles at `_build/sqlite/test` and its objects say so. The key has no
  build-path input — correctly, since the bytes do not differ — so one object
  serves projects that build in different places, and extracting it in place put
  the build tree where the consumer's Mix never looks. `validate_manifest/1` then
  found no manifest and reported *"the dependency build is outdated"*, the same
  sentence it uses for a lock mismatch, which is why this took days to find.

  Measured in the live store: three objects for `plug 1.20.3`, carrying
  `_build/test`, `_build/sqlite/test` and `_build/sqlite/prod`, every one
  recording a lock identical to the consumer's.

  Extraction is now staged and each tree moved to this member's own build path,
  so **existing objects become usable rather than needing a re-push**. Keys are
  unchanged, so no schema bump and no refill.

## v0.8.0 — 2026-10-03

**No object path changes, so no refill.** Keys are unchanged; schema stays `v3`.

A release about being able to say *why*. depdep could report that Mix refused a
restore and relay Mix's sentence; it could not say which input the key missed,
even while holding the `%Mix.Dep{}` and sitting beside the manifest. It can now.
It also has a specification, and CI fails on a claim nobody has checked.

- **`--explain-rebuilt`** (#134, #135): for each restore Mix refuses, print what
  the build's manifest recorded against what Mix expected — the Elixir and OTP
  pair, the SCM, and the lock entry with **the index of the first differing tuple
  element** named. Mix's own sentence, *"the dependency build is outdated"*,
  covers both a differing lock and an unreadable manifest and distinguishes
  neither. An absent manifest is reported as absent, which that sentence cannot
  say. Off by default, and silent when nothing is refused.

- **No more `redefining module` warnings** (#109, #132): `Mix.Project.in_project/4`
  caches by app atom, and Mix's converge loads a path dependency under its real
  app name — so asking about that directory as a *member* recompiled its
  `mix.exs` over the already-loaded module. One warning per path-dependency
  member per run: nine on a ten-member poncho, about fifty lines a job. Measured
  on `dco-tek/bizex`: **3 → 0**. This matters beyond tidiness, because stderr is
  where `restored, but Mix would rebuild it` goes.

- **Reclamation's third rail is fixed and tested** (#126). The refusal to sweep a
  store with no current roots — the rail that guards against the *operator* being
  wrong rather than the clock — had no test, and the helper it used treated an
  **unparseable root timestamp as stale** where `spec/08-reclamation.md#prefixes`
  says recent. A root whose age could not be read was dropped from the live set,
  exposing every object it protected. It now counts as current, and `--report`
  uses the same rule as `--sweep` so the report cannot disagree with the delete
  it precedes.

- **depdep has a specification** (#112): `spec/`, twelve numbered files, with the
  store's key format written down as the compatibility contract it has always
  been. It is held to the code by `surfex` relations and gated in CI, so a public
  function nobody described, or a test hint nobody verified, fails the build.
  Writing it found six defects, two of them in the specification itself.

- **surfex comes from hex** (#129) at `~> 0.5.16`, which removed the
  `CI_JOB_TOKEN` rewrite depdep's pipeline needed for an ssh-declared git
  dependency. It remains `only: [:dev, :test], runtime: false`: a published
  package of depdep still declares no dependencies, and a test reads
  `requirements` out of the built tarball to prove it.

### Known, and not fixed here

- **#122 and #110 are open.** In a poncho whose members share hex dependencies,
  or whose members are each other's path dependencies, v0.7.0 and v0.8.0 refuse
  more restores than v0.6.0 did. Correctness is not at risk — a refused restore
  is recompiled and counted as a miss — but the store saves less than it reports.
  `--explain-rebuilt` exists to find the mechanism; three hypotheses have been
  disproven by measurement so far.
- **#123 is open**: a restored git dependency keeps the pusher's `origin`, so two
  projects spelling the same repository differently see a lock mismatch.


## v0.7.0 — 2026-09-28

The key's inputs become Mix's own, and the profile learns to travel with the
data. **Every object path changes**: a consumer's first pipeline on this
version refills the store and the second is warm, so expect one cold run.
That refill is also the point — objects pushed by this version carry compile
times, which is what makes `depdep.saved` and `depdep.compile_carried` mean
anything.

- **The store-backed CI harness** proves two claims that shipped unverified:
  that `apt-get install` uses a restored `.deb`, and that `--report` and
  `--sweep` work against a real S3 server across a listing page boundary.
  Both run on every pipeline. (#104–#106, from #41)

- **`mix depdep.profile check --instance`**: asks an instance what it holds
  (`GET /api/v1/profiles/depdep`, with the ingest token depdep already has)
  and names every difference — a metric either side lacks, and for the ones
  in common, a `type`/`quantity`/`unit`/`polarity` that disagrees. A hash
  would have said "differs" without saying how, and the how is the point: the
  four compile-timing metrics were *present* on cn2 and catalogued as bare
  numbers. Runs in CI; a difference fails the job, an unreachable or
  unconfigured instance does not. The profile's own header no longer claims a
  tag publishes it. (#103, from #100)
- **`depdep.compile_carried`**: what the stored object says a dependency cost
  to compile, posted for every hit that carries one. `depdep.saved` is that
  number less the transfer and floored at zero, which makes it a saving
  rather than an addend — a panel that stacks transfer with `saved` reports
  the estimate as transfer whenever the clamp bites. Three dashboard panels
  read it: the run's estimated-vs-actual, the per-module transfer against the
  compile avoided, and a table of which dependencies the store earns its keep
  on. (#102, from #101)
- **The metresis profile travels with the data.** Every ingest post carries
  `Metresis-Profile: depdep sha256:<hash>`; an instance that lacks the hash
  answers `428 profile_missing`, depdep publishes the document with the same
  ingest token and retries once. Pending, rejected, queue-full and
  capability-less answers are one warning line each and exit 0. **Removed:**
  `mix depdep.profile publish`, the `publish-profile` tag job and
  `DEPDEP_METRESIS_ADMIN_TOKEN` — no admin token anywhere. Needs a metresis
  with #243. (#87, from #86)
- **The toolchain fingerprint is complete.** Every key carries the ERTS, the
  architecture and the compiler environment (`ERL_COMPILER_OPTIONS`,
  `ELIXIR_ERL_OPTIONS`, `MIX_TARGET`); a dependency with a native build
  additionally keys on the OS release and the C compiler. No NIF object is
  x86-64 bytes with nothing in its key to say so any more. (#95)
- **Schema v3: the key's inputs are Mix's own.** Children, the env rule and
  the build options a declaration carries (`env:`, `compile:`, `system_env:`
  — none of which was in the key before) come from the converge `mix deps`
  runs, asked inside the project; the parsed `mix deps.tree` graph, the
  hand-written `only:` walk and the lock's child parser are gone. A path
  dependency's closure is active because Mix lists it (#79, by construction).
  Before `mix deps.get`, where Mix's list is incomplete, nothing is excluded
  and `--mix-get`'s second pass settles it. **Every object path changes: a
  consumer's first pipeline on this version refills the store, the second is
  warm; v2 objects are left for `--sweep`.** (#94, from #89)

## v0.6.0 — 2026-09-21

The consumer-found defects of v0.5.0, and one URL for the store. A minor:
`DEPDEP_STORE` and `DEPDEP_METRESIS` add to the interface; a consumer's
bootstrap script and CI line change only in the tag, and every object path
is unchanged — no store refill.

- **`DEPDEP_STORE`**: one URL for the shape of the store —
  `s3://ACCESS_KEY@host:port/bucket?region=…` (`s3+https` for TLS) — beside
  `DEPDEP_SECRET_KEY`, which stays its own variable; a URL carrying a
  password is refused. The four separate variables keep working; both forms
  at once is refused. `DEPDEP_METRESIS` likewise beside
  `DEPDEP_METRESIS_URL`. (#88)
- **A restored dependency Mix would rebuild is a miss**, named with Mix's
  reason, and `--compile-deps` compiles it — `— rebuilt N` on the summary,
  `depdep.rebuilt_after_restore` posted. (#91, from uficap's #85)
- **A restore replaces the trees it carries.** A git dependency restored
  after `deps.get` failed with `:eacces` on git's read-only objects and was
  built from source on every consumer. (#99)
- **`--push --provider apt` no longer crashes** on the first `.deb` the
  store has not seen. (#90)
- **A path dependency makes the env walk incomplete**: its closure is
  requested rather than reported `not for this env` — bizex's 133 objects.
  (#92, from #79)
- `--compile-deps` holds an ambiguous unit on the no-store path too (#84);
  `mix docs` fails on a dead docstring reference (#82).

## v0.5.0 — 2026-09-20

A publishable package, and the leaf-git fix consumers are waiting on. Two new
Mix tasks make this a minor; nothing about a consumer's bootstrap script or CI
line changes but the tag.

- **`--compile-deps` names only misses this env is known to build.** A miss
  the env walk could only call ambiguous — possible when the dependency graph
  could not be read — is warned once and left to the consumer's `mix compile`
  rather than handed to `mix deps.compile`, which refuses it for the env and
  ended the run. (#83, from extc's #81)
- **Docs and a rehearsed publish.** `mix docs` builds through the ex_doc
  escript so `deps/0` stays `[]`; every `v*` tag runs `hex-dry-run`, the whole
  publish path against a placeholder key. A `publish-hex` job exists but does
  not run until `HEX_API_KEY` is set — publishing is a separate decision. (#77)
- **README for a reader outside the private network.** Getting started leads
  with the hex form; Status says what is measured and what is not. (#76)
- **The metresis profile ships in `priv/`** and `Depdep.Profile` finds it
  through `:code.priv_dir/1` at runtime instead of a path into the source
  tree, so a copy installed from a package can run `mix depdep.profile
  check`. (#74)
- **`mix depdep.profile publish`** POSTs the profile to `DEPDEP_METRESIS_URL`
  with `DEPDEP_METRESIS_ADMIN_TOKEN` and adopts it on that token's domain.
  Runs on `v*` tag pipelines only; a missing variable is a usage error, never
  a silent skip. (#72)
- **`priv/profiles/depdep.exs`**, the vocabulary of every metric depdep posts
  — units, polarity, descriptions, label keys and their expected values, and a
  starter dashboard. `mix depdep.profile check` diffs it against what the code
  emits, both ways, and runs in CI. Before this every key posted as a bare
  provisional gauge of `number`. (#71)
- **A leaf git dependency is keyed.** The second pass named only nodes with
  edges in `mix deps.tree --format dot`, so a git dependency with no children
  was never keyed and stayed `skipped` after `--mix-get`. Every node the dot
  touches is named now. (#70)
- **Package metadata:** `package/0` with an MIT license, a changelog and an
  explicit file list, so `mix hex.build` succeeds. Nothing is published. (#75)

## v0.4.0 — 2026-09-17

What the store saves, and a pull that owns `mix deps.get`.

- **`--mix-get`** runs `mix deps.get` inside the pull and decides again with
  the resolved graph in hand: the second `--pull` line consumers had to
  remember (two of four did not) is depdep's own second pass, over only the
  units the first could not settle. `deps.get`'s exit status becomes depdep's
  — that is the consumer's fetch, not the store's — while store trouble stays a
  warning and exit 0. (#64)
- **`--compile-deps`** runs one `mix deps.compile <names>` per member naming
  exactly the misses, so restored dependencies are never mentioned to Mix and
  nothing compiles twice. Each dependency's compile time is read off the
  boundaries Mix prints, kept beside the build, and posted as `depdep.compile`.
  Opt-in, because a dependency that does not compile ends the run with Mix's
  exit status. (#65)
- **A hit says what it saved.** `--push` carries the compile time with the
  object; a `--pull` reads it back with one `HEAD` and reports the compile not
  done, less what the transfer cost, as `saved_us` — on the summary line and
  as `depdep.saved` / `depdep.saved_total`. A lower bound: an object stored
  before this reports nothing, not zero, until a push that measured it. (#66)
- **`not for this env N`** on the summary line: a lock entry the current
  `MIX_ENV` never builds (`ex_doc` under `MIX_ENV=test`, say) is decided from
  `mix.exs` and the lock's edges before any key is computed or request made,
  and kept out of `missing` so that number can reach zero and mean it. (#62)
- The one-line hint after a usage error follows the error class — an unknown
  switch points at the switches, a bad environment variable at the variables.
  (#61)

## v0.3.0 — 2026-09-11

Depdep measures itself, and posts the result when given a token.

- **`DEPDEP_CONCURRENCY`**, an instrument rather than a tuning knob. Unset,
  depdep derives the limit from the scheduler count, clamped; set, the value
  is used exactly, so `DEPDEP_CONCURRENCY=1` is a genuinely serial run. A
  value that is not a positive integer, or above 256, is refused rather than
  clamped. It exists so the concurrency claim can be measured as two
  pipelines, one commit, one variable. (#53)
- **Per-provider, per-unit measurement.** Download and extraction are timed
  separately per unit, tallies are kept per provider instead of merged away
  before printing, and the run knows its concurrency and its parallelism
  (work done ÷ wall-clock). (#56)
- **Reporting to metresis.** With `DEPDEP_METRESIS_URL` and
  `DEPDEP_METRESIS_TOKEN` both set, the run's samples are posted with the
  project, commit, ref, pipeline and job GitLab already puts in the
  environment, so no pipeline needs editing. With either unset nothing is sent
  and no connection is opened. A refused connection, a 401, a 500 or a hang is
  a warning and exit 0; the `Idempotency-Key` derives from the pipeline and
  job so a retried job cannot double-count. (#57)

## v0.2.0 — 2026-09-08

An off switch.

- **`DEPDEP_ENABLED=false`** makes depdep report that it is off and exit 0,
  having read nothing — not the lockfile, not the config, not the store's
  credentials. Checked before anything else, so it works on a day when depdep
  itself is what is broken. Unset and empty mean enabled, as every other
  `DEPDEP_*` variable already reads. A value that is neither `true` nor
  `false` is refused, naming what is accepted, and exits 2: a
  `DEPDEP_ENABLED=flase` quietly meaning enabled would hand back a warm restore
  labelled as a cold build. `--help` answers regardless.

A minor rather than a patch: this adds to depdep's interface. It is the first
real v0.2.0 — a v0.2.0 and v0.3.0 referred to in early comments never existed
(#40 collapsed that series into v0.1.0).

## v0.1.2 — 2026-09-08

Config is evaluated with the member's `mix.exs` loaded.

- `Depdep.Member` is the one place depdep asks Mix about a member: build path
  and `config/config.exs` both run inside `Mix.Project.in_project/4`, so a
  config that calls into its own project (metresis chooses its Ecto adapter
  with `Metresis.MixProject.repo_adapter()`) evaluates instead of raising, and
  one that reads `Mix.Project.build_path()` no longer keys on the directory
  depdep was launched from. Each member's `mix.exs` compiles once per run.
  (#46, #47)
- Measured over every member of every consumer: metresis's root member reads
  its configured apps instead of crashing and its `esbuild`/`tailwind` objects
  re-key once; bizex's `hosts/snowex` re-keys `esbuild` once; extc is
  unchanged. A re-key is one miss, then a hit — never a wrong object.

## v0.1.1 — 2026-09-08

- The summary line says how long the transfer took —
  `depdep: pulled 148, pushed 0, skipped 3 in 12.4s`. The clock starts after
  `Mix.install` has cloned and compiled depdep, since that part is the
  consumer's cost and varies with the runner's cache. A patch: the counters,
  their order and their words are unchanged. (#42)
- README's Status section no longer names a v0.3.0 that #40 collapsed into
  v0.1.0.

## v0.1.0 — 2026-09-07

A content-addressed store for build artifacts, extracted from dco-tek/bizex,
where the original cut a poncho pipeline from ~28 minutes to 6m24s across 148
stored objects.

- **Compiled Elixir dependencies**, one object each, keyed by a recursive
  Merkle hash over the whole input closure — own source, toolchain,
  compile-time configuration, and the children's keys — so a restore is only
  ever the build the consumer would have produced. An object carries both
  the compiled `_build` tree and the `deps` source that produced it; restoring
  the build alone measured 9% slower than no store, because `mix deps.get`
  then rewrites the source and Mix recompiles everything. Git dependencies are
  keyed in a second pull after `deps.get`, from `mix deps.tree`.
- **Debian packages**, one object per `.deb`, keyed on the filename the
  distribution already guarantees unique, verified against apt's own checksum.
- **Git mirrors**, bare, for `--reference` clones, keyed on repository and
  month.
- Concurrent transfers, streaming uploads, `--report` and an operator-run
  `--sweep` with a pipeline identity that holds Get and Put and not Delete.
- **Failure is not an error:** every failure to reach or use the store is
  absorbed and the run exits 0. A `mix.lock` or `config/config.exs` depdep
  cannot read is the one exception — `mix deps.get` could not read it either.
- **No dependencies**, and it has to stay that way: depdep runs before
  `mix deps.get`, so anything it depended on would have to be fetched by the
  machinery it exists to get in front of.
