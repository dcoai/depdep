# depdep holds `spec/` to the code it describes: which spec sections and which
# public items somebody confirmed belong together, at which versions (#112).
# `mix surfex.status` is the check and `RELATIONS.md` is the committed record.
#
# `require:` and `triangle:` are DELIBERATELY ABSENT, and #120 adds them.
# Setting either before the spec has content would fail the check for all thirty
# modules from the first commit and keep failing for the length of the effort,
# which teaches everybody to ignore the gate — the failure
# `guides/writing-specs.md` §2 warns about, where relations get confirmed without
# being read. The gate arrives when there is something for it to hold.
#
# `sources:` matches NUMBERED files only, which is what keeps `spec/README.md`
# out: it says how the spec is organised and makes no claim about the code that
# anything could implement. `exclude:` does NOT do this job — it is applied by
# `Surfex.Cite.sources/2` to citation scanning, while sections come from
# `Surfex.Status.Config.scans/3`, which passes `sources` to the markdown scan
# untouched. Filed as dco-tek/surfex#68. The glob also makes the numbering rule
# self-enforcing: an unnumbered file is not part of the spec.
[
  sources: ["spec/[0-9]*.md"],
  tests: ["test/**/*_test.exs"],
  goldens: [:status]
]
