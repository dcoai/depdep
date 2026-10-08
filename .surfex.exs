# depdep holds `spec/` to the code it describes: which spec sections and which
# public items somebody confirmed belong together, at which versions (#112).
# `mix surfex.status` is the check and `RELATIONS.md` is the committed record.
#
# `sources:` matches NUMBERED files only, which is what keeps `spec/README.md`
# out: it says how the spec is organised and makes no claim about the code that
# anything could implement. `exclude:` does NOT do this job — it is applied by
# `Surfex.Cite.sources/2` to citation scanning, while sections come from
# `Surfex.Status.Config.scans/3`, which passes `sources` to the markdown scan
# untouched. Filed as dco-tek/surfex#68. The glob also makes the numbering rule
# self-enforcing: an unnumbered file is not part of the spec.
#
# ## The gate (#120)
#
# `require:` is the hard part, and both keys below are achievable TODAY rather
# than aspirationally:
#
#   * `code: [:implements, :excuses]` — every public item is either described by a
#     section or excused by a class. #112 planned for excusal classes and the first
#     adoption needed none, which was recorded here as a better outcome than the one
#     planned for. Three have since proved necessary, each for the same reason: an
#     item with no behaviour of its own has nothing a test can exercise, so a
#     relation on it could only be asserted. A module is a namespace (#138), `main/1`
#     halts so no test can call it and then assert (#137), and a type is a shape
#     (#183). Every public FUNCTION is still required to be described.
#   * `test_hint: [:verifies]` — every test hint is verified by a tagged test.
#
# ## Why `triangle:` is NOT `:fail`
#
# A correction to #112, not a deferral — see `spec/10-decisions.md#the-gate`.
# Closing the triangle requires every section's verifying test to call every
# function that section cites. `spec/04-store-layout.md#s3` cites twelve;
# `spec/02-architecture.md` is a map whose sections describe module groupings no
# single test can meaningfully verify. Setting `:fail` would demand hollow tests
# or the dismantling of the map, and hollow tests are how a gate teaches people
# to confirm without reading — the failure `guides/writing-specs.md` §2 exists to
# prevent. The triangle is reported in every run instead, and closing a gap where
# it is genuinely closeable is ordinary work.
# ## Adoption (#129)
#
# `:trust` takes the suite as it stands, once. surfex 0.5 validates an
# `implements` relation by what a test DID — failed, then passed against the code
# — and refuses to let a human assert one by hand. depdep's 392 tests already
# pass, so they cannot honestly go red against code they were written beside;
# there is nothing for them to discriminate. `mix surfex.baseline` records that
# trust explicitly, with a note saying why, rather than leaving every relation
# silently unvalidated.
#
# Trust only shrinks from here: an edited test's new version is not trusted, and a
# test's first real red→green moves its relations from `baseline` to `evidence`.
#
# `baseline:` is left at its default — REPORTED, not `:fail`. Same judgement as
# #120 made on `triangle:`, and for the same reason: the 110 triangle gaps and the
# 177 unvalidated relations are one fact under two names, and gating on it would
# demand hollow tests. See `spec/10-decisions.md#the-gate`.
# ## Excusals (#137)
#
# `classes`/`rules` get their first use, and #120 was wrong to report them
# unnecessary — they were unnecessary only because a halting wrapper had been
# CITED where it should have been excused.
#
# `Depdep.CLI.main/1` calls `System.halt/1`. No test can call it and then assert,
# so a claim cited against it can only ever be asserted, never shown. Its
# decisions — `parse/1`, `disposition/1`, `combination/2`, `hint/1` — are each
# public and tested for exactly that reason, which the source says out loud.
#
# The rule is BY CLASS, never by item, so another halting entry point added later
# falls into it quietly while a new decision matches no rule and is a gap.
[
  classes: [
    # #138. A module item's own story is its functions', and each of those is cited
    # where it is described. The architecture map used to describe modules as
    # groupings, but a map relation cannot be validated — no test verifies "these
    # modules are the run's shape" — so it dangles for ever and drowns the signal
    # from relations that can go current.
    #
    # The gate stays meaningful: every public FUNCTION must still be described or
    # excused, so a new module arrives with undescribed functions and is caught
    # there. The hole this leaves is a module with no public functions at all,
    # which would be excused silently; `spec/02-architecture.md#not-described`
    # records that.
    {"module container",
     "A module is a namespace. The behaviour the spec describes is its functions', " <>
       "each cited where it is described; the module item carries none of its own."},
    {"halting entry point",
     "It calls System.halt/1, so no test can call it and then assert. What it " <>
       "decides is the spec's subject and is cited there; this wires those " <>
       "decisions to IO and an exit status."},
    # surfex 0.6 made each `@type` a code item (#183, for #180). A type states the
    # SHAPE of data, and a shape has no behaviour to verify: no test run exercises a
    # type, so an `implements` on one could only ever be asserted, never shown — the
    # same reason the architecture map's module relations were excused above.
    #
    # Where the spec describes a shape in substance it may still cite the type and
    # relate it, by judgement; the class is the default, not a bar.
    {"type",
     "A type is the shape of the data its functions take and return. The behaviour " <>
       "is theirs and is cited where each is described; a shape has nothing a test " <>
       "can exercise, so a relation on it could only be asserted."}
  ],
  rules: [
    # `name` matches the bare item name, the module being `parent`. `main/N` rather
    # than this one function: an entry point is named by convention, so another
    # added later falls into the class quietly, which is what "by class, never by
    # item" means.
    %{class: "halting entry point", kinds: [:function], name: ~r/^main\/\d+$/},
    %{class: "module container", kinds: [:module]},
    %{class: "type", kinds: [:type]}
  ],
  adoption: :trust,
  sources: ["spec/[0-9]*.md"],
  tests: ["test/**/*_test.exs"],
  goldens: [:status],
  # ## What is NOT required, and why (#159)
  #
  # The rule this project wants is surfex's own `triangle: :fail` — "a spec unit, its
  # tests and its code must meet". #159 triaged the 21 sections that had `implements`
  # relations and no verifying test anywhere: 20 were owed a verifier and 18 of those
  # already had a passing test that was simply never connected. One (`#warts`) was
  # genuinely exempt, because it records defects rather than specifying behaviour and
  # says so — its relations were retired rather than excused. One (`#report`) had no
  # section at all.
  #
  # That subset is now clear: no section with implementing code lacks a verifier.
  # `triangle: :fail` still cannot be turned on — 105 gaps remain, 90 of the form
  # "implements it but no verifying test CALLS it" and 14 "verifies it but calls none
  # of its code". Closing those is its own effort.
  #
  # `section: [:verifies]` is NOT the encoding, and the reason is worth recording so
  # nobody tries it again: 76 sections would fail it, because depdep's convention is
  # that a `test` hint carries the `verifies` and REFINES its section. The hint rule
  # below already holds that end.
  require: [code: [:implements, :excuses], test_hint: [:verifies]]
]
