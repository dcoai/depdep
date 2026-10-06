# Depdep

Do a piece of build work **once per distinct build**, and restore it everywhere
else.

Depdep is a content-addressed store for build artifacts, with three providers:
compiled Elixir dependencies, Debian packages, and git mirrors. Each keys its
objects in the way that is actually sound for that kind of artifact, and those
ways differ sharply — a `.deb` needs nothing more than its own filename, while a
compiled dependency needs a hash of everything that went into it.

The mix provider is the deepest of the three, and the three sections that follow
are about it. **It stores each compiled Elixir dependency as its own object,
keyed by a recursive Merkle hash over that dependency's entire input closure.** A
restore is therefore only ever the build the consumer would have produced itself.
For the other two, see
[apt packages and git mirrors](guide/03-apt-and-git.md).

*On the name: it was shortened from "dependency depot", back when a dependency
was the only thing it stored. The packages and the mirrors came later, and the
name stayed.*

## What problem this solves

Two different ones, depending on the shape of the project.

**In a poncho** — several independent Mix projects in one repository, each with
its own `deps/` and `_build/` — the same package is compiled once per member.
Measured on the project this was extracted from: 564 dependency instances over
113 distinct packages, with `ash` compiled ten times at 44 s a pass. Depdep
collapsed that to 148 stored objects and cut CI from ~28 minutes to 6m24s.

**In a single project** the win is across *pipelines* rather than members:
compiled dependencies persist between CI runs. That is what a CI cache normally
does — the difference is correctness, below.

## Why not just use a CI cache

A CI cache is one opaque archive per key, restored wholesale, after which Mix
decides what is stale by comparing source mtimes against build manifests. **A
cache restore steps around the machinery Mix uses to stay correct**, and the
failure is silent: you get a build that compiles clean, passes its tests, and is
wrong.

Depdep's key is computed from the inputs, so a stored object either matches what
you would have built or is not returned at all.

See [Design notes](guide/05-design.md) for why the hash recurses and why
depdep has no dependencies.

## The specification

`spec/` is the normative description of depdep: the object key format and its
schema versioning, the store's layout, the providers, the run, the metric
vocabulary, and the reclamation rules. `spec/README.md` says how it is organised
and how to add to it.

This README is documentation — what depdep does, how to configure it, and why the
design is what it is. `spec/` is the contract. Where the two disagree, `spec/`
wins and the README is wrong.

Sections are held to the code they describe: each names its functions, and a
recorded relation remembers the versions both ends had when somebody last
confirmed they matched. Change either end and the relation dangles until someone
reads both again. `RELATIONS.md` is the committed record, and CI fails on a
relation nobody has looked at.

## Installing it

Depdep runs *before* `mix deps.get`, so it cannot be a dependency in your
`mix.exs` — that would be circular. It is a script you commit, which installs
depdep for itself:

```elixir
# scripts/depdep.exs
Mix.install([{:depdep, "~> 0.10"}])

Depdep.CLI.main(System.argv())
```

[Getting started](guide/01-getting-started.md) has the rest: pointing it at a
store, the form to use when installing from git rather than hex, wiring it into
CI, and checking that it works.

## The guide

The detail that used to live here, so this page can stay an introduction:

| | |
|---|---|
| [Getting started](guide/01-getting-started.md) | what you need, pointing it at a store, the bootstrap script, wiring it into CI, and checking it works |
| [Poncho projects](guide/02-poncho-projects.md) | several Mix projects in one repository |
| [apt packages and git mirrors](guide/03-apt-and-git.md) | the other two providers |
| [Reclaiming the store](guide/04-reclamation.md) | what `--report` and `--sweep` do, and the rails on them |
| [Design notes](guide/05-design.md) | why the hash recurses, why there are no dependencies, and why a failure is not an error |

`spec/` is the normative specification and is a different thing from a guide — see
[The specification](#the-specification).

## Prior art

Depdep is not the first attempt at this problem, and one of the earlier ones is
the better answer if you are already set up for it. Worth knowing what you are
choosing between.

### Nix is the closest relative

[`deps_nix`](https://github.com/code-supply/deps_nix) and
[`mix2nix`](https://github.com/ydlr/mix2nix) turn each `mix.lock` entry into
its own Nix derivation. A Nix store path is a hash over that derivation's
inputs, and those inputs include the store paths of the children it was built
against — **the same recursion this README spends a section arguing for, except
obtained by construction rather than by argument.** Put a binary cache behind
it and you have depdep's restore, with reported CI reductions in the same
range. If you already run Nix, use it; nothing here is worth adding a second
mechanism for.

Two differences, and the first is the substantive one:

- **Compile-time configuration is part of depdep's key.** A dependency's
  derivation is a function of *that dependency's* inputs. Your
  `config/config.exs` is not among them — it belongs to the consumer project,
  outside the dependency entirely. But `Application.compile_env/2` and
  module attributes bake values from it into the dependency's bytecode, which
  is why two members that configure the same package differently need
  different objects. `Depdep.Config` puts a per-app slice of exactly that
  configuration into the key. What a derivation-keyed store returns in that
  situation is a question worth asking of whichever tool you pick.
- **No Nix, and no generated file to keep in sync.** Depdep reads `mix.lock`
  at the moment it runs, so there is no checked-in derivation set that can
  drift from the lock it was generated from.

### Bazel is the general answer, and is not available here

Action-level content hashing plus a remote cache is this problem solved in
general, for every language at once. It is not an option on the BEAM today:
[`rules_erlang`](https://github.com/rabbitmq/rules_erlang) is unmaintained —
RabbitMQ moved back to erlang.mk once it caught up — and there is no working
`rules_elixir`. Worth knowing so you don't go looking.

### Precompiled artifacts are the ecosystem's precedent, not a competitor

[`rustler_precompiled`](https://github.com/philss/rustler_precompiled),
[`elixir_make`](https://github.com/elixir-lang/elixir_make) with
[`cc_precompiler`](https://hexdocs.pm/cc_precompiler/precompilation_guide.html),
and [Nerves](https://hexdocs.pm/nerves/) system artifacts all say "download
this rather than compile it", so the idea needs no defending here. The
mechanism is a different one: those artifacts are *publisher*-produced, keyed
on package version plus target triple, and cover native code. Depdep's are
*consumer*-produced, keyed on the whole input closure, and cover Elixir
bytecode. They do not overlap, and a project can use both.

### Mix itself

Two open issues describe this problem from inside Mix.
[elixir-lang#12520](https://github.com/elixir-lang/elixir/issues/12520)
proposes keeping compiled dependencies in `_build` **keyed by version**, so
switching branches stops costing a recompile — the local form of what depdep
does across machines, under exactly the key `Depdep.Key` shows to be unsound:
bump `spark` and `ash`'s version does not move while its correct bytecode does.
[elixir-lang#14425](https://github.com/elixir-lang/elixir/issues/14425) covers
git dependencies against CI caches. Both are open.

[Elixir 1.19](https://elixir-lang.org/blog/2025/10/16/elixir-v1-19-0-released/)
attacks the same wall-clock cost from the other end:
`MIX_OS_DEPS_COMPILE_PARTITION_COUNT` compiles dependencies in parallel across
OS processes, reportedly up to 4x faster. **These compose, and you want both.**
Depdep removes compilations; 1.19 makes the remaining ones cheaper — and the
set it makes cheaper is precisely depdep's `missing N`.

## Status

**In use.** Depdep runs first in the CI of the projects it was built
alongside, restoring compiled Elixir dependencies and Debian packages on every
pipeline. It found its first two defects there — a 403 on any key holding a
reserved character, and a `build_path` that made it serve a directory Mix never
reads — both fixed in v0.1.0. What each release changed is in
[CHANGELOG.md](CHANGELOG.md).

**A restore costs time when it is wrong; it does not corrupt.** This is the
claim to read first, because it is the one every defect found so far has
confirmed. An object either matches the inputs Mix would have built from, or it
is not returned — and when depdep gets that judgement wrong, the failure has
always been to *refuse* work it could have done, never to serve a build that
did not belong. v0.7.0 shipped a real instance of this (#122, #131): objects
carry the pusher's `build_path`, so a restore could land where the consumer's
Mix never looks. It cost recompiles at seven consumers for three weeks. Nothing
was mis-built.

**What it saves, measured across the fleet on 2026-10-04.** Per pipeline, the
store's reported saving against depdep's own cost:

| project | saved | depdep's cost | net |
|---|---|---|---|
| bizex | 178.9 s | 52.8 s | **+126 s** |
| metresis | 40.4 s | 1.5 s | +39 s |
| visualize | 29.7 s | 3.9 s | +26 s |
| visualize2 | 30.0 s | 5.5 s | +25 s |
| extc | 20.7 s | 12.4 s | +8 s |
| extla | 12.0 s | 3.9 s | +8 s |

**Net positive at every consumer, in tens of seconds to two minutes.** That is
the number to plan against. A much larger figure exists and is also real: the
poncho depdep was extracted from went from **~28 minutes to 6m24s** across 148
objects. That was one project at one commit, with a cold cache and 215
dependencies to compile — an upper bound on what a first adoption can win, not
what a warm pipeline sees. Treat the table as the expectation and the 28 minutes
as the ceiling.

**What a wrong judgement is currently costing.** `depdep.rebuilt_after_restore`,
latest per consumer: bizex **219**, extc 12, visualize2 8, visualize 1, extla 1;
metresis, uficap, exio and depdep 0. Each one is an object transferred and then
recompiled anyway — waste, not breakage. v0.9.0 should reduce these once
consumers pin it; #122, #110 and #133 stay open until a consumer's pipeline says
by how much, and #123 is a second cause not yet addressed.

**Per-pull cost**, over the network: 1.3–1.6 s for 44 Debian packages, 3.2–4.2 s
for ~50 compiled dependencies. A restored git mirror measured 2.43 s cold against
0.57 s on a 7.4 MB repository.

**On the key rules.** Extracting depdep from the poncho it grew in was verified
by replaying it: the same eleven projects computed **564 byte-identical keys**,
and every object already in the store was one the extracted code asked for. That
showed the extraction changed no key — a refactor check, and a good one. It is
not evidence about the rules in force today, which are schema `v3`; the keys it
compared were `v2`.

Every figure above is dated and re-takeable. The savings and rebuild counts come
from the metrics store (one query per metric, grouped by project); the store's
own contents come from `--report` against the live bucket, recorded on issue #41.

**Measured, and worth knowing before relying on it.** Every mechanism below
is now exercised where it can be seen, not asserted.

- **Concurrency is not where the time is.** Measured on extc (34 objects,
  ~1 MiB average, MinIO on the LAN; eight pipelines, serial and derived
  alternating, one at a time): the whole pull line took a median **9.5 s
  serial against 8.9 s concurrent** — about a second, 1.1×, direction
  consistent and magnitude inside the spread. The synthetic 26.9× quoted
  earlier was an upper bound on overlap against injected latency and is not
  what a consumer sees; at this scale the transfer is a small share of the
  pull. `DEPDEP_CONCURRENCY=1` stays as the instrument for anyone with a
  larger store or a slower link.
- **apt uses the restored `.deb`.** Every pipeline runs the round trip under
  root: download, push, empty the archives directory, pull, then
  `apt-get install` — asserting **no `Get:` lines** and that the package is
  configured. A control in the same job asserts the fetch before it *does*
  print `Get:`, so the assertion cannot pass by accident.
- **Reclamation runs against a real S3 server.** Every pipeline fills a
  throwaway store with over a thousand objects — enough to cross the
  1000-per-page listing boundary, so a real continuation token is signed
  against a server that enforces Signature v4 — then asserts what `--report`
  says, that `--sweep` without `--confirm` removes nothing, and that with it
  exactly the objects no root references go.

  What no container can answer is what the *production* bucket holds, so that
  was taken by hand on 2026-10-04 (#41):

  ```
  922 roots, 922 written in the last 30 days
  apt/v1   269 objects,  211.1 MiB — 236 reachable,  33 not ( 26.8 MiB)
  v2       569 objects, 1229.4 MiB — 382 reachable, 187 not (451.9 MiB)
  v3/…     128 groups                                 (one row per package)
  ```

  Three things worth reading off it. **The live set is real**: 922 roots, every
  one refreshed inside the window, so reclamation would have a live set to work
  from rather than refusing. **`v2` is still live** — consumers pinned to v0.6.0
  still push and pull it — and it holds 1229.4 MiB of which 451.9 MiB is
  unreachable, the largest reclaimable thing in the store. **`apt/v1` has 33
  unreachable objects and that is by design**: apt is never swept
  (`spec/08-reclamation.md#prefixes`).

  The 128 `v3/` rows are one per package where there should be one row in total,
  which is #125 — a reporting defect, visible here in production for the first
  time.

**Not on hex.pm yet.** The package builds (`mix hex.build`) and every tag
rehearses a publish, but no version has been published; until one is, install
it from git as [Getting started](guide/01-getting-started.md) shows.
