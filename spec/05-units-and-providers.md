# Units and providers

Depdep moves three kinds of thing: compiled Elixir dependencies, Debian
packages, and git mirrors. The store, the signing, the concurrency, the
fail-safe reporting and the bucket accounting are indifferent to which.

## What a unit is {#unit}

A **unit** is one thing that can be stored and restored: one compiled
dependency of one project, one `.deb`, one repository mirror.

`Depdep.Unit` is the struct. A unit is what a provider hands back and the only
thing the transfer loop ever handles.

Everything a provider needs in order to act on a unit later lives in its
`:context`, and **nothing outside that provider reads it**. That is what lets the
transfer loop stay ignorant of what it is moving.

`:group` and `:name` are separate because they are printed as separate columns,
and a provider with no grouping leaves `:group` as `nil` rather than inventing
one. `Depdep.Unit.label/1` is the printable name.

## What a provider must answer {#contract}

`Depdep.Provider` is the behaviour. Four things, and they are the only things
that differ between kinds of artifact:

| Callback | Question |
|---|---|
| `enumerate/1` | what is wanted, and what does each key to |
| `present?/1` | is this one already satisfied on disk |
| `restore/2` | put a fetched object where the tool that needs it will look |
| `collect/2` | turn what is on disk into an object |

`Depdep.Provider.known/0` lists them, `Depdep.Provider.resolve/1` turns names
from the command line into modules, `Depdep.Provider.default/0` is the one used
when none is named, and `Depdep.Provider.name/1` is the reverse.

**Iteration belongs to the provider, not the caller.** The mix provider walks
poncho members, each with their own `deps/` and `_build/`; a package provider has
no such notion. So `enumerate/1` yields a flat list and keeps its traversal to
itself.

**A key is a provider's own business.** Only the mix provider needs a recursive
Merkle hash, and the reason it does is `spec/03-keys.md#recursion`. Nothing else
is expected to recurse.

## Compiled Elixir dependencies {#mix}

`Depdep.Provider.Mix`. A unit is one dependency of one project, and `:group` is
the project directory — so a poncho's eleven members each contribute their own
`ash`, each reported under its own name.

Everything Mix-specific lives behind this module: the key, the one place Mix is
asked, the lock reader, the configuration slice, poncho discovery and the
archive rule. **A key or an object path that moves here silently retires every
object in every consumer's store**, which is why the boundary is worth keeping
sharp.

`Depdep.Provider.Mix.present?/1` decides whether a dependency is already
satisfied on disk. `Depdep.Provider.Mix.Get.run/3` is `--mix-get`, specified in
`spec/06-the-run.md`.

## Debian packages {#apt}

`Depdep.Provider.Apt`, so a job does not re-download packages from a mirror.

**Depdep runs in the same apt environment as the install it is serving.** That
is what makes this simple: `apt-get install --print-uris` is not a guess about
what some other image would resolve — it is apt itself reporting what it is
about to fetch, in the environment that will fetch it.
`Depdep.Provider.Apt.parse_uris/1` reads that output.

`Depdep.Provider.Apt.restore/2` drops the files into the archives directory,
where `apt-get install` looks before reaching for the network.
`Depdep.Provider.Apt.verify/2` checks a restored file against what apt expects.
`Depdep.Provider.Apt.suite/0` names the distribution release, which is also a
key input for native builds (`spec/03-keys.md#native`).

**Depdep's responsibility ends at populating a directory.** Nothing here runs
`apt-get install`, edits sources, or takes a view on the consumer's pipeline.

**Nothing here recurses, and that is not a shortcut.** A `.deb` has no property
like an Elixir dependency's: it is built once by the distribution for everyone,
its contents do not change when its dependencies change, and
`name_version_arch.deb` already identifies it exactly.

**A `.deb` a store has never seen is uploaded, not a crash.** A file ending in
`.deb` is a unit, so this needs no apt on the machine doing the push.

```test apt-first-sighting
given an archives directory holding a .deb the store does not have
when a push runs
then the file is uploaded and the run exits 0
```

## Git mirrors {#git}

`Depdep.Provider.Git` stores bare mirrors, so a clone is a local copy rather
than a network transfer. The consumer clones against one with
`--reference`/`--dissociate`. As everywhere else, depdep's responsibility ends
at putting something on disk — **it never clones a repository for anyone**.

**A stale mirror is not a wrong answer**, and this is the fact the whole design
rests on. It is the opposite of the mix provider's situation. A wrong mix object
is a build that compiles clean, passes its tests and is wrong. A mirror is only a
*seed*: whatever it contains, the consumer's own fetch reconciles it against the
real remote. An out-of-date mirror costs a larger delta and nothing else. There
is no silent-wrong-answer failure mode here to defend against.

That is what makes the key cheap. Objects are keyed on the repository and a
monthly **epoch** rather than on a commit: `Depdep.Provider.Git.epoch/0` is the
current epoch, `Depdep.Provider.Git.slug/1` names the repository, and
`Depdep.Provider.Git.mirror_path/1` is where a mirror lands.

Reclamation keeps the newest epochs per repository rather than computing
reachability — `spec/08-reclamation.md`.

## Archives {#archive}

An object is a compressed tar. `Depdep.Archive.create` builds one and
`Depdep.Archive.extract` restores it.

`Depdep.Archive.create_trees` is what walks the two trees into the archive.

**An object carries `deps/` source as well as the `_build/` tree, and both or it
recompiles.** `Depdep.Archive.trees` names the two trees and
`Depdep.Archive.complete?` answers whether both are present: a dependency with
a build but no source counts as **absent**, because Mix will rebuild it.

A restore **replaces** existing trees, read-only files and leftovers included,
and puts the archived mtimes back so a restored manifest stays newer than the
sources beside it. Archiving a dependency that is not there is an error rather
than an empty archive.

**A tree is restored where THIS member builds, not where the pusher built.** An
object's entry names are relative to the pusher's project root, so the pusher's
`build_path` is baked into them — a project that sets `build_path` carries
`_build/<something>/<env>/lib/<name>` where another carries `_build/<env>/…`. The
key has no build-path input and should not have one, because the bytes do not
differ, so one object legitimately serves projects that build in different
places.

Extracting such an object in place put the build tree where the consumer's Mix
never looks, and Mix then reported the dependency as outdated — the restore
check's reason, with no way to tell it from a lock mismatch
(`spec/06-the-run.md#restore-check`). So the extraction is staged and each tree
is moved to the path `spec/05-units-and-providers.md#build-path` gives for this
member. The pusher's build directory is not left behind.

A tree the object does not carry, or one matched ambiguously, is an **error** and
the unit becomes a miss. That costs a compile; placing a tree on a guess would
cost correctness.

```test restore-lands-at-this-members-build-path
given an object archived from _build/sqlite/test/lib/<name>
when it is restored into a project that builds at _build/test
then the manifest is readable at _build/test/lib/<name>/.mix
and the pusher's build directory is not left behind
```

```test archive-both-trees
given a dependency with a _build tree and no deps source
then it counts as absent rather than present
```

## Where a build lives {#build-path}

`Depdep.BuildPath.for_project/2` answers where a project builds.

A project that says nothing builds where everyone builds; a project that sets
`build_path` builds where it says; the environment is not appended twice; a
directory with no `mix.exs` falls back rather than failing. **A build path
outside the project is refused, with a reason** — serving a directory Mix never
reads was one of depdep's first two production defects.
