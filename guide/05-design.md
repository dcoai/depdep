# Design notes

*Part of [depdep's guide](../README.md#the-guide). Back to the [README](../README.md).*

## Why the hash recurses

A dependency's compiled output is a function of its dependencies' compiled
output, not merely of their version numbers. `use Spark.Dsl` expands spark's
macros **into ash's beam files**; bump spark and ash's correct bytecode changes
while ash's own version and inner checksum stay byte-identical.

Mix handles this correctly during a normal build by tracking compile-time
dependencies. A cache layer has to re-establish that invariant for itself:

```
key(dep) = sha256(
  schema_version,                       # v3
  elixir, otp, erts, arch, mix_env,     # the toolchain, and the compiler environment
  [os_release, cc],                     # only for a dependency with a native build
  name, version, inner_checksum,        # the dep's own source: the lock entry
  build_tools,                          # mix / rebar3 / make, from the lock
  env, compile, system_env,             # the declaration's build options, from Mix
  config_digest(dep.app),               # compile-time config reaching it
  for each child Mix lists, sorted:
    optional and absent -> ("absent",  name)
    otherwise           -> ("present", name, key(child))   # <- recursion
)
```

**Every input is Mix's own.** The lock entry is Mix's; the children, the
`only:` rule that decides what this env builds, and the build options a
declaration carries (`env:`, `compile:`, `system_env:`) come from the same
converge `mix deps` runs, asked inside your project — not from a parsed
lockfile, a parsed `mix deps.tree`, or a hand-written walk of the `only:`
rule, which is how depdep did it through v0.5 and where every defect it
shipped lived. Nothing is re-derived; the key is enumerable.

A dependency with a native build — one whose lock entry names `elixir_make`,
`rustler`, `zigler`, `cc_precompiler` or a `make` build — additionally keys
on the OS release and the C compiler, since that is what its bytes depend on;
a pure-Elixir dependency does not rekey when the image's `gcc` moves.

Compile-time configuration is in the key for the same reason: `Application.compile_env/2`
and module-level attributes bake values into bytecode, so two members that
configure a package differently need different objects.

**Upgrading past v0.5 refills the store once.** The v3 key changes every
object path, so each consumer's first pipeline on this version is a cold pull
that pushes everything again, and the second is warm. The `v2` objects left
behind are reclaimed by `--sweep`, which removes a retired schema's objects
without consulting the live set at all — stale roots still name them, so
marking would have spared them indefinitely.

## Why no dependencies

Depdep runs **before `mix deps.get`**. Anything it depended on would have to be
fetched by the very machinery it exists to get in front of. AWS Signature v4 is
about sixty lines, and `:httpc` and `:erl_tar` ship with OTP, so the whole client
is written out here rather than taken from a library.

This is a hard constraint, not a preference, and it is stated normatively in
`spec/01-goals-and-scope.md`. What it forbids is a **runtime** dependency. Depdep
does carry one build-time dependency — surfex, which holds the specification to
the code it describes — declared `only: [:dev, :test], runtime: false`. Such
dependencies are not transitive, so nothing reaches a project that depends on
depdep, and a published package of depdep declares no dependencies at all. Two
tests in `test/depdep/mix_project_test.exs` hold both halves of that.


## Failure is not an error

Any problem reaching the store — no credentials, unreachable host, wrong secret,
a corrupt object — is reported and then ignored, and the run exits 0. The worst
outcome of a broken depot is that Mix compiles the dependency, which is what it
would have done anyway. A build tool that can fail your pipeline for a *cache
miss* has made things worse.

**Two files sit outside that promise, and it is worth being exact about which.**
Depdep reads your `mix.lock` and your `config/config.exs`; if either cannot be
read, the run exits non-zero rather than carrying on. That is deliberate. A
lockfile that does not parse is one `mix deps.get` cannot parse either, so the
pipeline was going to stop at the next command regardless — depdep stops it one
command earlier and names the file. What it never does is absorb a broken
project into a slow one.
