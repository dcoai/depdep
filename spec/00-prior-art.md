# Prior art

Depdep is not the first attempt at this problem, and one of the earlier answers
is the better one if you are already set up for it. This file records what depdep
is chosen *instead of*, and why — so that the choice stays a decision rather than
becoming an assumption.

Nothing here is a requirement on depdep. It is the context the requirements were
written in, kept beside them because a comparison that lives only in somebody's
memory gets re-litigated every year.

Deliberately no code is cited in this file. Naming a function here would relate
this prose to that function as though it implemented these paragraphs, which
would put a comparison's relations in the way of the requirements' relations.
Where a claim about depdep needs a reference, it points at the section that
states it normatively.

## Nix is the closest relative {#nix}

`deps_nix` and `mix2nix` turn each `mix.lock` entry into its own Nix derivation.
A Nix store path is a hash over that derivation's inputs, and those inputs
include the store paths of the children it was built against — **the same
recursion `spec/03-keys.md#recursion` argues for, obtained by construction
rather than by argument.** Put a binary cache behind it and you have depdep's
restore, with reported CI reductions in the same range.

**If you already run Nix, use it.** Nothing in depdep is worth adding a second
mechanism for.

Two differences, the first substantive:

- **Compile-time configuration is part of depdep's key**
  (`spec/03-keys.md#config`). A dependency's derivation is a function of *that
  dependency's* inputs, and the consumer's `config/config.exs` is not among
  them — it belongs to the consumer project, outside the dependency entirely.
  But `Application.compile_env/2` and module attributes bake values from it into
  the dependency's bytecode, which is why two members configuring the same
  package differently need different objects. What a derivation-keyed store
  returns in that situation is a question worth asking of whichever tool is
  chosen.
- **No Nix, and no generated file to keep in sync.** Depdep reads `mix.lock` at
  the moment it runs, so there is no checked-in derivation set that can drift
  from the lock it was generated from.

## Bazel is the general answer, and is not available here {#bazel}

Action-level content hashing plus a remote cache is this problem solved in
general, for every language at once. It is not an option on the BEAM today:
`rules_erlang` is unmaintained — RabbitMQ moved back to erlang.mk once it caught
up — and there is no working `rules_elixir`.

Recorded so nobody spends a day looking for it.

## Precompiled artifacts are the ecosystem's precedent {#precompiled}

`rustler_precompiled`, `elixir_make` with `cc_precompiler`, and Nerves system
artifacts all say "download this rather than compile it", so the idea needs no
defending.

The mechanism is a different one, and the two do not overlap:

| | Precompiled artifacts | depdep |
|---|---|---|
| Produced by | the publisher | the consumer |
| Keyed on | package version + target triple | the whole input closure |
| Covers | native code | Elixir bytecode (and packages, and mirrors) |

A project can use both, and depdep's key accounts for the interaction: a
dependency built by one of those tools is treated as native
(`spec/03-keys.md#native`), because its bytes are target-specific whether it
compiled them or downloaded them.

## Mix itself {#mix-itself}

Two open Elixir issues describe this problem from inside Mix.
`elixir-lang/elixir#12520` proposes keeping compiled dependencies in `_build`
**keyed by version**, so switching branches stops costing a recompile — the
local form of what depdep does across machines, under exactly the key
`spec/03-keys.md#recursion` shows to be unsound: bump `spark` and `ash`'s
version does not move while its correct bytecode does.
`elixir-lang/elixir#14425` covers git dependencies against CI caches. Both are
open.

Elixir 1.19 attacks the same wall-clock cost from the other end:
`MIX_OS_DEPS_COMPILE_PARTITION_COUNT` compiles dependencies in parallel across
OS processes, reportedly up to 4× faster.

**These compose, and both are wanted.** Depdep removes compilations; 1.19 makes
the remaining ones cheaper — and the set it makes cheaper is precisely the units
depdep reports as missing.

## A CI cache is the thing depdep is most often mistaken for {#ci-caches}

A CI cache is one opaque archive per key, restored wholesale, after which Mix
decides what is stale by comparing source mtimes against build manifests.

**A cache restore steps around the machinery Mix uses to stay correct**, and the
failure is silent: a build that compiles clean, passes its tests, and is wrong.
The measured instance is recorded in `spec/03-keys.md#recursion` —
`Ash.Type.File.Source` resolving to `Any` while 106 of 106 tests passed.

Depdep's key is computed from inputs, so a stored object either matches what
would have been built or is not returned at all. That is the whole difference,
and it is why "just use the CI cache" is not the same proposal.
