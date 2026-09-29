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
[
  sources: ["spec/[0-9]*.md"],
  tests: ["test/**/*_test.exs"],
  goldens: [:status],
  require: [code: [:implements], test_hint: [:verifies]]
]
