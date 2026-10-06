# Poncho projects

*Part of [depdep's guide](../README.md#the-guide). Back to the [README](../README.md).*

Several independent Mix projects in one repository, each with its own `deps/`
and `_build/`. **Nothing needs to be said** — depdep treats every `mix.exs`
beneath the root as a member, at any depth, and a package compiled for one is
restored for the others whenever the inputs agree. A root `mix.exs` of its own
makes no difference: a poncho with a root coordinator project gets the root
*and* its members, not the root instead of them.

A `mix.exs` with no `mix.lock` beside it is not a member — there is nothing to
key without a lock — which is what separates buildable members from path
dependencies a parent compiles. Depdep says how many it passed over, once, so
the number is never a surprise:

```
depdep: 14 directories have a mix.exs but no mix.lock — not members, nothing to key
```

**First, check that you need this.** If your members can share one build — an
umbrella, or plain projects pointing `build_path`, `deps_path`, `config_path`
and `lockfile` at a common root ([`Mix.Project`](https://hexdocs.pm/mix/Mix.Project.html),
which is all an umbrella does) — then Mix already compiles each package once
for all of them, at no cost and with no store to run. Do that instead.
Depdep's poncho case is for members that deliberately *cannot* share a build:
independent dependency sets, members on different toolchains, or a boundary
between them that has to stay real.

**Where a member compiles to is asked of the member, not assumed.** Almost every
project builds into `_build/<env>`, and depdep used to take that literally. A
project that sets `build_path` in its `mix.exs` — because two variants cannot
share one build, say — compiles elsewhere, and depdep would restore into a
directory Mix never reads: a restore *and* a full compile, with nothing
reporting a problem. It now asks `Mix.Project` for each member's build path, so
`build_path: "_build/sqlite"` is found and used.

The same goes for `config/config.exs`: it is evaluated with the member's
`mix.exs` loaded, so config that calls a function from its own project module
— choosing an Ecto adapter, say — or asks `Mix.Project.build_path()` for
esbuild's `NODE_PATH` sees the member's answers. Evaluated with no project
loaded, the first raised and the second answered from whichever directory
depdep was run from, which put the cwd into a key.

The build path is deliberately **not** part of any key. Identical bytecode does
not depend on the directory it was written to, so two variants of a project that
differ only in where they build share their dependency objects, which is the
point.

Two options for when the default is wrong:

```sh
# a member on a different toolchain has nothing to share, so skip the scan.
# --exclude takes a path prefix, matched on whole segments: this drops
# clients/wasm and leaves clients_vendor/ alone.
elixir scripts/depdep.exs --pull --exclude clients

# and since a toolchain varies per member, not per top-level group, a prefix
# can go as deep as it needs to
elixir scripts/depdep.exs --pull --exclude logic-analyzer/eval

# or name the members explicitly, which always wins over discovery
elixir scripts/depdep.exs --pull --project platform/crm --project hosts/app
```

This is where the deduplication is largest: the project this was extracted from
compiled 564 dependency instances over 113 distinct packages every pipeline.
