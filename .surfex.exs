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
#   * `code: [:implements]` — every public item is described by a section. There
#     are no `classes` and no `rules` because nothing needed excusing: the spec
#     describes all thirty modules' public surface. #112 planned for excusal
#     classes; they turned out to be unnecessary, which is a better outcome than
#     the one planned for.
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
       "decisions to IO and an exit status."}
  ],
  rules: [
    # `name` matches the bare item name, the module being `parent`. `main/N` rather
    # than this one function: an entry point is named by convention, so another
    # added later falls into the class quietly, which is what "by class, never by
    # item" means.
    %{class: "halting entry point", kinds: [:function], name: ~r/^main\/\d+$/},
    %{class: "module container", kinds: [:module]}
  ],
  adoption: :trust,
  sources: ["spec/[0-9]*.md"],
  tests: ["test/**/*_test.exs"],
  goldens: [:status],
  require: [code: [:implements, :excuses], test_hint: [:verifies]]
]
