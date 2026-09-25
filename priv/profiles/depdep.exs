# The depdep profile: what a depdep run posts to metresis, and how to read it.
#
# This is the emitter's own vocabulary (metresis #206, spec §3.3): the metric
# keys, their units and polarity, the label keys and their expected values, and
# a starter dashboard. `mix depdep.profile check` holds it to what
# `Depdep.Metresis` actually emits, both ways, and `mix depdep.profile publish`
# POSTs it on tag with `adopt: true`.
#
# An Elixir map literal rather than YAML, and string keys throughout: depdep has
# no dependencies (README §"Why no dependencies"), `Depdep.Json` encodes this as
# it stands, and metresis's `POST /api/v1/profiles` takes JSON of the same keys
# its `priv/profiles/*.yml` uses. The one cost is that `guidance` is a heredoc
# rather than a block scalar. Keep the file a literal: nothing here may compute.
%{
  "key" => "depdep",
  "name" => "Depdep",
  "description" =>
    "What restoring compiled dependencies from a depdep store cost a CI job, and what it saved.",
  "version" => 1,
  "guidance" => """
  One depdep run is one `--pull` or one `--push` in one job, and it posts two
  kinds of number. **Per run and per provider** — `depdep.elapsed`, `depdep.span`,
  `depdep.bytes_total`, `depdep.units`, `depdep.concurrency`,
  `depdep.parallelism`, `depdep.saved_total` — say what the run cost and how
  much of the lock it settled. **Per unit** — `depdep.download`, `depdep.extract`,
  `depdep.bytes`, `depdep.compile`, `depdep.saved` — say where the time went,
  one sample per dependency, labelled by `unit` and by the `bucket` it landed
  in.

  **Read `bucket` before anything else.** A pull ends each dependency in one of
  `pulled` (restored from the store), `missing` (the store had no object — a
  genuine miss), `present` (already on disk and confirmed current), `skipped`
  (depdep cannot key it, almost always a git dependency before `deps.get`) or
  `not_for_env` (the job's `MIX_ENV` never builds it — never requested). A push
  ends each in `stored`, `uploaded`, `not_built` or `skipped`. The question the
  dashboard exists to answer is whether `missing` trends to zero; `skipped` and
  `not_for_env` are structural and must be kept out of it.

  **`depdep.saved` is a lower bound, and absent is not zero.** A hit reports
  the compile it did not do, less what the download and extraction cost; the
  source fetch `mix deps.get` was spared is saved too but cannot be attributed
  to one package, so it is left out. An object stored before compile times were
  carried (v0.4.0) reports no `saved` at all — a project with no `saved` series
  is one whose objects predate `--compile-deps`, not one that saves nothing.

  **`depdep.parallelism` is read against `depdep.concurrency`.** Units transfer
  8–32 at a time, so the summed per-unit time exceeds the phase's span; the
  ratio is how many were genuinely in flight. A parallelism of 6 under a
  concurrency of 32 says the limit was not the constraint.

  `depdep.compile` carries `measured`: `exact` when Mix's own boundary lines
  bracketed the compile, `boundary` when a rebar3 dependency's start was
  measured to the next boundary and includes rebar's startup.

  `project`, `ref` and `provider` are the dimensions to split by. `pipeline`,
  `job`, `commit` and `unit` identify one run or one dependency: filter to
  them, never group by them.
  """,
  "unit_defaults" => %{"duration" => "s", "bytes" => "MB"},
  "label_keys" => [
    %{
      "key" => "project",
      "role" => "dimension",
      "description" => "The GitLab project the job ran in (`CI_PROJECT_PATH`). The usual group-by."
    },
    %{
      "key" => "ref",
      "role" => "dimension",
      "description" => "The branch or tag (`CI_COMMIT_REF_SLUG`)."
    },
    %{
      "key" => "direction",
      "role" => "dimension",
      "description" => "Whether the run was a `--pull` or a `--push`.",
      "expected_values" => ["pull", "push"]
    },
    %{
      "key" => "provider",
      "role" => "dimension",
      "description" => "Which artifact kind the phase moved: compiled Elixir dependencies, Debian packages or git mirrors.",
      "expected_values" => ["mix", "apt", "git"]
    },
    %{
      "key" => "bucket",
      "role" => "dimension",
      "description" =>
        "Where a dependency ended: on a pull `pulled`, `missing`, `present`, `skipped` or `not_for_env`; on a push `stored`, `uploaded`, `not_built` or `skipped`.",
      "expected_values" => [
        "pulled",
        "missing",
        "present",
        "skipped",
        "not_for_env",
        "stored",
        "uploaded",
        "not_built"
      ]
    },
    %{
      "key" => "measured",
      "role" => "dimension",
      "description" =>
        "How a compile time was taken: `exact` from Mix's own boundaries, `boundary` from a rebar3 start to the next boundary.",
      "expected_values" => ["exact", "boundary"]
    },
    %{
      "key" => "unit",
      "role" => "annotation",
      "description" => "One dependency of one project, as `member/name`. Identifies; never group by it."
    },
    %{
      "key" => "reason",
      "role" => "annotation",
      "description" => "Why a unit missed or was skipped — the store's error, or depdep's own reason. Truncated to 120 characters."
    },
    %{
      "key" => "job_name",
      "role" => "dimension",
      "description" => "The CI job's name (`CI_JOB_NAME`), so a `checks` pull and a `test` pull can be told apart."
    },
    %{
      "key" => "pipeline",
      "role" => "annotation",
      "description" => "GitLab's pipeline id. Identifies one run; filter to it."
    },
    %{
      "key" => "job",
      "role" => "annotation",
      "description" => "GitLab's job id. Identifies one run; filter to it."
    },
    %{
      "key" => "commit",
      "role" => "annotation",
      "description" => "The commit the pipeline ran for."
    },
    %{
      "key" => "run",
      "role" => "annotation",
      "description" => "A random id for a run outside CI, where there is no pipeline or job to key on."
    }
  ],
  "metrics" => [
    %{
      "key" => "depdep.elapsed",
      "name" => "Run elapsed",
      "group_name" => "Run",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 1,
      "polarity" => "higher_worse",
      "description" =>
        "The whole transfer, from the first provider to the last — what depdep itself cost the job. Excludes the Mix.install that bootstrapped it and any compile."
    },
    %{
      "key" => "depdep.rebuilt_after_restore",
      "name" => "Rebuilt after restore",
      "group_name" => "Run",
      "type" => "gauge",
      "quantity" => "count",
      "precision" => 0,
      "polarity" => "higher_worse",
      "description" =>
        "Restored dependencies Mix would rebuild anyway, counted as misses with Mix's reason. Above zero means the key missed an input; the day it happens is the day to look."
    },
    %{
      "key" => "depdep.saved_total",
      "name" => "Time saved",
      "group_name" => "Run",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 1,
      "polarity" => "higher_better",
      "description" =>
        "The run's hits together: compile time not done, less transfer cost. A lower bound; absent when no object in the run carried a compile time."
    },
    %{
      "key" => "depdep.span",
      "name" => "Phase span",
      "group_name" => "Phase",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 1,
      "polarity" => "higher_worse",
      "description" => "Wall-clock time of one provider's concurrent phase."
    },
    %{
      "key" => "depdep.concurrency",
      "name" => "Concurrency",
      "group_name" => "Phase",
      "type" => "gauge",
      "quantity" => "number",
      "precision" => 0,
      "polarity" => "neutral",
      "description" =>
        "How many transfers were allowed at once — derived from the scheduler count, or `DEPDEP_CONCURRENCY` when a measurement is being taken."
    },
    %{
      "key" => "depdep.parallelism",
      "name" => "Effective parallelism",
      "group_name" => "Phase",
      "type" => "gauge",
      "quantity" => "number",
      "precision" => 2,
      "polarity" => "higher_better",
      "description" =>
        "Summed per-unit time divided by the phase's span: how many units were genuinely in flight. Read against `depdep.concurrency`."
    },
    %{
      "key" => "depdep.bytes_total",
      "name" => "Bytes moved",
      "group_name" => "Phase",
      "type" => "gauge",
      "quantity" => "bytes",
      "unit" => "B",
      "precision" => 0,
      "polarity" => "neutral",
      "description" => "Compressed bytes the phase moved, both directions."
    },
    %{
      "key" => "depdep.units",
      "name" => "Units by bucket",
      "group_name" => "Phase",
      "type" => "gauge",
      "quantity" => "count",
      "precision" => 0,
      "polarity" => "neutral",
      "description" =>
        "How many dependencies ended in each `bucket`. `missing` is the number that should trend to zero; `skipped` and `not_for_env` are structural."
    },
    %{
      "key" => "depdep.download",
      "name" => "Download",
      "group_name" => "Unit",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 3,
      "polarity" => "higher_worse",
      "description" => "One unit off the network (or, on a push, onto it)."
    },
    %{
      "key" => "depdep.extract",
      "name" => "Extract",
      "group_name" => "Unit",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 3,
      "polarity" => "higher_worse",
      "description" => "One unit unpacked into place (or, on a push, tarred up)."
    },
    %{
      "key" => "depdep.bytes",
      "name" => "Object size",
      "group_name" => "Unit",
      "type" => "gauge",
      "quantity" => "bytes",
      "unit" => "B",
      "precision" => 0,
      "polarity" => "neutral",
      "description" => "One unit's compressed object."
    },
    %{
      "key" => "depdep.compile",
      "name" => "Compile time",
      "group_name" => "Unit",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 2,
      "polarity" => "higher_worse",
      "description" =>
        "How long a miss took to compile under `--compile-deps` — the one moment the number exists. `measured` says how exactly."
    },
    %{
      "key" => "depdep.saved",
      "name" => "Saved",
      "group_name" => "Unit",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 2,
      "polarity" => "higher_better",
      "description" =>
        "What one hit saved: the compile it did not do, less its download and extraction. Absent when the object carried no compile time."
    },
    %{
      "key" => "depdep.compile_carried",
      "name" => "Compile carried",
      "group_name" => "Unit",
      "type" => "gauge",
      "quantity" => "duration",
      "unit" => "s",
      "precision" => 2,
      "polarity" => "neutral",
      "description" =>
        "What the stored object says this dependency cost to compile when it was built. The estimate a hit avoided, unclamped — `depdep.saved` is this less the transfer and floored at zero, which makes it a saving rather than an addend. Absent when the object predates --compile-deps."
    }
  ],
  "dashboards" => [
    %{
      "name" => "Depdep",
      "layout" => %{
        "panels" => [
          %{
            "title" => "What depdep cost, by project (p95)",
            "viz" => "line",
            "x" => 0,
            "y" => 0,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.elapsed"],
              "aggregation" => "p95",
              "group_by" => ["project"]
            }
          },
          %{
            "title" => "Time saved per run, by project",
            "viz" => "line",
            "x" => 6,
            "y" => 0,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.saved_total"],
              "aggregation" => "mean",
              "group_by" => ["project"]
            }
          },
          %{
            "title" => "Misses (the number that should reach zero)",
            "viz" => "bar",
            "x" => 0,
            "y" => 4,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.units"],
              "aggregation" => "sum",
              "group_by" => ["project"],
              "filters" => [%{"key" => "bucket", "op" => "eq", "value" => "missing"}]
            }
          },
          %{
            "title" => "Units by bucket",
            "viz" => "stacked_bar",
            "x" => 6,
            "y" => 4,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.units"],
              "aggregation" => "sum",
              "group_by" => ["bucket"]
            }
          },
          %{
            "title" => "Compile time per miss (p95)",
            "viz" => "line",
            "x" => 0,
            "y" => 8,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.compile"],
              "aggregation" => "p95",
              "group_by" => ["project"]
            }
          },
          %{
            "title" => "Parallelism against concurrency",
            "viz" => "line",
            "x" => 6,
            "y" => 8,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.parallelism", "depdep.concurrency"],
              "aggregation" => "mean",
              "group_by" => ["provider"]
            }
          },
          # Estimated against actual: the bottom band is what the run cost,
          # the top is the compile it did not do. Both are durations in
          # seconds, so they share an axis and the stack is a real sum.
          %{
            "title" => "Estimated vs actual — the run",
            "viz" => "stacked_area",
            "x" => 0,
            "y" => 12,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.elapsed", "depdep.saved_total"],
              "aggregation" => "mean",
              "filters" => [%{"key" => "direction", "op" => "=", "value" => "pull"}]
            }
          },
          # NOT "estimated vs actual": the compile never happened, so the top
          # band is hypothetical rather than time this pipeline spent. Named
          # for what it is (#101's evaluation).
          %{
            "title" => "Restored: transfer against the compile avoided",
            "viz" => "stacked_bar",
            "x" => 6,
            "y" => 12,
            "w" => 6,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.download", "depdep.extract", "depdep.compile_carried"],
              "aggregation" => "mean",
              "filters" => [
                %{"key" => "direction", "op" => "=", "value" => "pull"},
                %{"key" => "bucket", "op" => "in", "value" => ["pulled", "present"]}
              ]
            }
          },
          # Which dependencies the store is earning its keep on.
          %{
            "title" => "By module: what compiling would cost, against what restoring did",
            "viz" => "table",
            "x" => 0,
            "y" => 16,
            "w" => 12,
            "h" => 4,
            "query" => %{
              "v" => 1,
              "metrics" => ["depdep.compile_carried", "depdep.download", "depdep.extract"],
              "aggregation" => "mean",
              "group_by" => ["unit"],
              "limit" => 20,
              "filters" => [
                %{"key" => "direction", "op" => "=", "value" => "pull"},
                %{"key" => "bucket", "op" => "in", "value" => ["pulled", "present"]}
              ]
            }
          }
        ]
      }
    }
  ]
}
