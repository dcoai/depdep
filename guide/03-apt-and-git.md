# Other providers: apt packages and git mirrors

*Part of [depdep's guide](../README.md#the-guide). Back to the [README](../README.md).*

## Caching apt packages too

A job that installs a few packages before it builds re-downloads them from a
Debian mirror every pipeline. The same depot can hold those, with the same
credentials and the same fail-safe rules — `--provider apt`.

**This one is simple, and it is meant to be.** `Depdep.Key` recurses because an
Elixir dependency's compiled output is a function of its dependencies' compiled
output. A `.deb` has no such property: the distribution built it once for
everyone, its contents do not change when its dependencies change, and
`name_version_arch.deb` already identifies it exactly. **So the key is the
filename**, the object is the `.deb` itself, and nothing is hashed.

```yaml
variables:
  # one place, so the list cannot drift out of step with itself
  APT_PACKAGES: "libsodium-dev imagemagick"

script:
  # Debian images delete each .deb as it installs. Without this, --push finds
  # an empty directory and the store never warms.
  - rm -f /etc/apt/apt.conf.d/docker-clean
  - apt-get update
  - elixir scripts/depdep.exs --pull --provider apt ${APT_PACKAGES// / --package }
  - apt-get install -y $APT_PACKAGES
  - mix test
  - elixir scripts/depdep.exs --push --provider apt
```

- **`--pull` asks apt what it is about to fetch** — `apt-get install
  --print-uris` — and restores those files into `/var/cache/apt/archives`.
  `apt-get install` looks there before it reaches for the network. Depdep's job
  ends at populating a directory; it never runs apt for you, edits your sources,
  or takes a view on your pipeline.
- **`--push` reads that directory** and uploads whatever the store does not
  already have. It does not ask apt again — once the packages are installed,
  `--print-uris` reports nothing, because apt has nothing left to fetch.
- **Run `apt-get update` first.** Without a package index apt cannot resolve
  anything, and depdep will say so and restore nothing rather than guess.
- **Delete `/etc/apt/apt.conf.d/docker-clean` before installing.** Debian's
  images ship it, and it deletes every `.deb` as it is installed — so `--push`
  finds an empty archives directory, uploads nothing, and the store never warms.
  Nothing fails; it simply looks as though the provider does not work. Setting
  `APT::Keep-Downloaded-Packages "true"` does the same job.
- **`git` cannot be one of the packages depdep serves you.** `Mix.install`
  clones depdep, so git has to be in the image already — it is needed before
  depdep can bootstrap at all, let alone restore anything.
- **Depdep must run in the same container as the `apt-get install` it serves.**
  That is what makes `--print-uris` trustworthy: it is apt, in the environment
  that will do the installing, reporting exactly what it would fetch. Run it
  somewhere else — a different base image, the runner host — and it answers for
  the wrong machine.
- **Restored packages are verified** against the checksum apt itself reported.
  A mismatch is a miss, so apt downloads it; a corrupt object never reaches a
  package manager. The mix provider has no equivalent, because nothing tells it
  what a compiled dependency should hash to.
- `--apt-cache-dir` moves the directory if yours is not the default
  `/var/cache/apt/archives`.

Objects live under `apt/v1/<distribution>-<codename>/`, so they can be browsed,
and so two distributions cannot collide on a filename:

```
apt/v1/debian-trixie/libsodium-dev_1.0.18-1_amd64.deb
```

Nothing about this changes the mix provider. With no `--provider`, depdep does
exactly what it did before, so an existing bootstrap script keeps its meaning.

## Mirroring git repositories

A job that clones a large repository pays for it every pipeline. `--provider git`
keeps a bare mirror in the depot; the consumer clones against it and transfers
almost nothing.

```yaml
script:
  - elixir scripts/depdep.exs --pull --provider git --repo "$BIG_REPO"
  - git clone --reference .depdep/git/$(basename $BIG_REPO .git).git --dissociate "$BIG_REPO" checkout
  - elixir scripts/depdep.exs --push --provider git --repo "$BIG_REPO"
```

Measured against `github.com/philss/rustler_precompiled`, a 7.4 MB repository:

```
cold clone                        2.43 s
clone against a restored mirror   0.57 s
```

**A stale mirror is not a wrong answer, and that is the whole design.** A wrong
mix object still compiles clean and still passes its tests — which is why
`Depdep.Key` recurses over the entire input closure. A mirror is only a *seed*:
whatever it holds, your own clone reconciles it against the real remote, so an
out-of-date mirror costs a slightly larger transfer and nothing else.

That is what lets the key be cheap. An object is keyed on the repository and the
**month**, not on a commit:

```
git/v1/github.com-philss-rustler_precompiled/2026-09/mirror.tar.gz
```

- Each monthly object is written once and never modified, so the store stays
  append-only.
- Storage is bounded by months rather than by commits — keying per commit would
  store a full mirror per push.
- The worst case is **one cold clone per repository per month**: the first
  pipeline of the month misses, clones normally, and its `--push` stores the
  mirror for every pipeline after it. Nothing to schedule and nothing to
  bookkeep.
- `--push` produces the mirror itself when the store does not already have this
  month's, so the store fills without anyone priming it.
- `--git-mirror-dir` moves the mirrors if `.depdep/git` does not suit.

`git@host:group/proj` and `https://host/group/proj.git` are the same repository
and share one mirror, so reaching it two ways does not store it twice.
