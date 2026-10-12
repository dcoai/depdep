# Fills a throwaway store so `--report` and `--sweep` meet a real S3 server
# rather than a socket fixture (#106).
#
# Two things only a filled store can exercise. **More than one listing page**:
# `Depdep.S3.list/2` sends `list-type=2` with no `max-keys`, so a second page
# means over a thousand objects, and a second page means a continuation token,
# whose query-parameter signing (#28) either works or answers 403. And **a
# live set**: some objects a root references and some nothing does, so the
# sweep has both verdicts to reach.
{:ok, cfg} = Depdep.S3.config()
Depdep.S3.start()

packages = String.to_integer(System.get_env("FILL_PACKAGES") || "10")
per_package = String.to_integer(System.get_env("FILL_PER_PACKAGE") || "105")

payload = Path.join(System.tmp_dir!(), "depdep-fill-payload")
File.write!(payload, "not a real archive")

# `--report` groups by package, so a thousand one-object packages would print
# a thousand lines and say nothing. Ten packages of a hundred versions is the
# shape a real store has, and still crosses the 1000-object page boundary.
key = fn p, v -> "v3/pkg#{p}/1.0.#{v}/#{String.pad_leading("#{p}-#{v}", 12, "0")}.tar.gz" end
keys = for p <- 1..packages, v <- 1..per_package, do: key.(p, v)

# **A retired schema too, because its rule is the one a root cannot save** (#197, for
# #196). `Depdep.Sweep.verdict/6` hands back a retired object unconditionally, ignoring
# the live set — the single place where "a root names it, so keep it" is deliberately
# false, and the most destructive verdict depdep has.
#
# `sweep_test.exs` covers the decision in both directions. What no store job has ever
# done is the combination against a real server: depdep READING a root out of S3,
# parsing it, finding it naming these objects, and deleting them anyway. Every job's
# root named live-schema keys only, so that path has run against an in-memory MapSet
# and nothing else.
#
# Planted by default rather than behind a variable: an opt-in would leave whoever adds
# the next store job to decide whether this rule is covered, which is #189's complaint
# over again — only the newest job proving the newest thing.
retired_schema = hd(Depdep.Key.retired())

retired_key = fn p, v ->
  "#{retired_schema}/pkg#{p}/0.9.#{v}/#{String.pad_leading("r#{p}-#{v}", 12, "0")}.tar.gz"
end

retired_keys = for p <- 1..2, v <- 1..3, do: retired_key.(p, v)

(keys ++ retired_keys)
|> Task.async_stream(fn k -> :ok = Depdep.S3.put(cfg, k, payload) end,
  max_concurrency: 32,
  timeout: 120_000
)
|> Stream.run()

# One root, written now, naming the first version of each package: the sweep
# must keep exactly those and take the rest. `--sweep` refuses outright when
# no root is recent, so this is also what makes the run legal.
#
# **And naming two retired objects, which is the point of planting them.** A root that
# names a retired path is not a hypothetical — it is what a store looks like after a
# schema bump, written by a version of depdep nobody runs any more. The sweep must take
# them regardless, and a job that proves it has to make the root say otherwise first.
live = for p <- 1..packages, do: key.(p, 1)
named_retired = Enum.take(retired_keys, 2)

root = Path.join(System.tmp_dir!(), "depdep-fill-root")
File.write!(root, Depdep.Roots.encode(live ++ named_retired))
:ok = Depdep.S3.put(cfg, Depdep.Roots.path("ci-consumer", "main", "mix"), root)

IO.puts(
  "filled: #{length(keys)} objects in #{packages} packages, " <>
    "#{length(live)} referenced by one root, 1 root object"
)

IO.puts(
  "planted: #{length(retired_keys)} #{retired_schema} objects (retired schema), " <>
    "#{length(named_retired)} of them named by that same root — all #{length(retired_keys)} " <>
    "must be swept anyway"
)
