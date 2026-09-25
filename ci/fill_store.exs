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

keys
|> Task.async_stream(fn k -> :ok = Depdep.S3.put(cfg, k, payload) end,
  max_concurrency: 32,
  timeout: 120_000
)
|> Stream.run()

# One root, written now, naming the first version of each package: the sweep
# must keep exactly those and take the rest. `--sweep` refuses outright when
# no root is recent, so this is also what makes the run legal.
live = for p <- 1..packages, do: key.(p, 1)
root = Path.join(System.tmp_dir!(), "depdep-fill-root")
File.write!(root, Depdep.Roots.encode(live))
:ok = Depdep.S3.put(cfg, Depdep.Roots.path("ci-consumer", "main", "mix"), root)

IO.puts(
  "filled: #{length(keys)} objects in #{packages} packages, " <>
    "#{length(live)} referenced by one root, 1 root object"
)
