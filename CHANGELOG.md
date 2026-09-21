# Changelog

What changed for a user of depdep, per release. Each version is a git tag;
the four earliest also carry GitLab release notes, from which these entries
are condensed. Issue numbers are dco-tek/depdep's.

## Unreleased

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
