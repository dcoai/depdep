defmodule Depdep.Metresis do
  @moduledoc """
  Posts a run's measurements to a metresis instance, when one is configured.

  **Both variables unset means no request is attempted at all**, so every
  consumer that ignores this is unaffected and nothing in a pipeline changes.
  Nothing is asked of a consumer repository: the variables are CI settings, and
  the labels come from the environment GitLab already provides.

  ## Failure is not an error, here more than anywhere

  `dco-tek/metresis`'s `.gitlab-ci.yml` runs depdep with **no `|| echo` guard**,
  because depdep is trusted not to fail a pipeline over the store. A metrics
  post is even less entitled to: the measurement is a by-product of work that has
  already succeeded. A 4xx, a 5xx, a timeout or a refused connection warns and
  returns; the run's exit code never changes.

  ## Its own timeouts, and why they are not S3's

  `Depdep.S3` gives `:httpc` a 15 s connect and **300 s** request timeout, which
  is right for moving a 400 MB object. Inheriting that here would let an
  unresponsive metresis add five minutes to every job in every consumer — the
  opposite of "log and continue". These are passed per request, so they override
  the global options `Depdep.S3.start/0` sets.

  ## Idempotency

  `Idempotency-Key` (spec §7.2) is derived from the pipeline, job and direction
  rather than generated at send time, so a runner that retries a job posts the
  same key and metresis writes nothing the second time. §7.2 is explicit that a
  duplicated `tally` is silently wrong in a way no later inspection can
  distinguish from a real one.

  ## Staying under the cap

  metresis caps a request body at 2,000,000 bytes — "roughly ten thousand
  samples" — and a 413 rejects the WHOLE post, so an oversized body loses every
  sample rather than some. Depdep's worst case today is ~1,700 samples
  (`dco-tek/bizex`, 556 units), which is headroom rather than a live problem;
  `@max_samples` makes it a bounded property instead of a lucky one by chunking
  into several documents, each with its own key.
  """

  @connect_timeout 5_000
  @request_timeout 15_000

  # Half metresis's stated ~10k, so a document is comfortably inside the byte
  # cap even when every sample carries labels.
  @max_samples 5_000

  @doc """
  `{:ok, config}` when both variables are set, `:disabled` otherwise.

  Empty reads as unset, as the store's variables and `Depdep.CLI.enabled?/0` do.
  """
  def config do
    with {:ok, url} <- instance(),
         {:ok, token} <- env("DEPDEP_METRESIS_TOKEN") do
      base = String.trim_trailing(url, "/")

      {:ok,
       %{url: base <> "/api/v1/ingest", profiles_url: base <> "/api/v1/profiles", token: token}}
    else
      :unset -> :disabled
      {:error, reason} -> {:error, reason}
    end
  end

  # `DEPDEP_METRESIS` is the instance's URL, the same value `DEPDEP_METRESIS_URL`
  # holds, under the shorter name the store's `DEPDEP_STORE` set (#88). Both at
  # once is refused rather than merged, as the store's two forms are.
  defp instance do
    case {env("DEPDEP_METRESIS"), env("DEPDEP_METRESIS_URL")} do
      {{:ok, _}, {:ok, _}} ->
        {:error, "DEPDEP_METRESIS and DEPDEP_METRESIS_URL are both set — use one"}

      {{:ok, url}, :unset} ->
        {:ok, url}

      {:unset, {:ok, url}} ->
        {:ok, url}

      {:unset, :unset} ->
        :unset
    end
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> :unset
      "" -> :unset
      value -> {:ok, String.trim(value)}
    end
  end

  @doc """
  Labels every sample in the run shares, from the environment GitLab provides.

  Absent keys are omitted rather than filled with "unknown": a label that lies
  is worse than one that is missing, and metresis can group by what is there.
  """
  def labels(direction) do
    %{
      "project" => System.get_env("CI_PROJECT_PATH"),
      "commit" => System.get_env("CI_COMMIT_SHA"),
      "ref" => System.get_env("CI_COMMIT_REF_SLUG"),
      "pipeline" => System.get_env("CI_PIPELINE_ID"),
      "job" => System.get_env("CI_JOB_ID"),
      "job_name" => System.get_env("CI_JOB_NAME"),
      "direction" => to_string(direction)
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> keyable()
  end

  # Outside CI there is no pipeline or job, and a run with nothing to key on
  # cannot be idempotent. Two local runs are genuinely different events rather
  # than a retry of one, so each gets its own id — which keeps
  # `idempotency_key/3` total instead of raising on the one caller that is not
  # a pipeline.
  defp keyable(%{"pipeline" => _, "job" => _} = labels), do: labels
  defp keyable(labels), do: Map.put(labels, "run", run_id())

  defp run_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc """
  The idempotency key: pure, so the same job retried produces the same key.

  Outside CI there is no pipeline or job to key on, and two local runs are
  genuinely different events rather than a retry of one — so the caller supplies
  a per-run value and the key stays a function of its inputs.
  """
  def idempotency_key(%{"pipeline" => pipeline, "job" => job}, direction, chunk),
    do: "depdep-#{pipeline}-#{job}-#{direction}-#{chunk}"

  def idempotency_key(%{"run" => run}, direction, chunk),
    do: "depdep-local-#{run}-#{direction}-#{chunk}"

  @doc """
  The samples for one run, as metresis §4.1 wants them.

  Durations are **seconds**, not the microseconds the `--metrics` JSON carries:
  a store wants the natural unit, and §4.1's own example is `build.duration`
  in seconds.
  """
  def samples(map) do
    run =
      [
        sample("depdep.elapsed", seconds(map.elapsed_us), %{}),
        sample("depdep.rebuilt_after_restore", map.rebuilt_after_restore, %{})
      ] ++ saved_total(map)

    run ++ Enum.flat_map(map.phases, &phase_samples/1)
  end

  # `nil` is a run whose hits carried no compile time — a store built before
  # #66, or a push side without --compile-deps — and says nothing, not zero.
  defp saved_total(%{saved_total_us: nil}), do: []
  defp saved_total(%{saved_total_us: us}), do: [sample("depdep.saved_total", seconds(us), %{})]

  defp phase_samples(phase) do
    provider = %{"provider" => phase.provider}

    phase_level =
      [
        sample("depdep.span", seconds(phase.span_us), provider),
        sample("depdep.concurrency", phase.concurrency, provider),
        sample("depdep.bytes_total", phase.bytes, provider)
      ] ++ parallelism(phase, provider) ++ tally_samples(phase, provider)

    phase_level ++ Enum.flat_map(phase.units, &unit_samples(&1, provider))
  end

  # `nil` for a phase that did no work, and a sample that says nothing is worse
  # than no sample — §1.3's "absence is not zero" applies to what we send too.
  defp parallelism(%{effective_parallelism: nil}, _provider), do: []

  defp parallelism(phase, provider),
    do: [sample("depdep.parallelism", phase.effective_parallelism, provider)]

  defp tally_samples(phase, provider) do
    Enum.map(phase.tally, fn {bucket, count} ->
      sample("depdep.units", count, Map.put(provider, "bucket", to_string(bucket)))
    end)
  end

  defp unit_samples(unit, provider) do
    labels =
      provider
      |> Map.put("unit", unit.label)
      |> Map.put("bucket", to_string(unit.bucket))
      |> put_reason(unit.reason)

    [
      sample("depdep.download", seconds(unit.download_us), labels),
      sample("depdep.extract", seconds(unit.restore_us), labels),
      sample("depdep.bytes", unit.bytes, labels)
    ] ++
      compile_sample(unit, labels) ++ saved_sample(unit, labels) ++ carried_sample(unit, labels)
  end

  defp saved_sample(%{saved_us: nil}, _labels), do: []
  defp saved_sample(unit, labels), do: [sample("depdep.saved", seconds(unit.saved_us), labels)]

  # What the object says the dependency cost to compile, unclamped — the
  # estimate a hit avoided, and the only form of it that can be summed or
  # ranked per unit. `saved` is this less the transfer and floored at zero,
  # which makes it a saving rather than an addend (#101).
  defp carried_sample(%{compile_carried_us: nil}, _labels), do: []

  defp carried_sample(unit, labels),
    do: [sample("depdep.compile_carried", seconds(unit.compile_carried_us), labels)]

  # Only a unit that was actually compiled carries the number; "absence is not
  # zero" again. The measurement's kind rides along as a label so a dashboard
  # can show rebar3's boundary spans apart from Mix's exact ones.
  defp compile_sample(%{compile_us: nil}, _labels), do: []

  defp compile_sample(unit, labels) do
    kind = if unit.compile_exact, do: "exact", else: "boundary"
    [sample("depdep.compile", seconds(unit.compile_us), Map.put(labels, "measured", kind))]
  end

  defp put_reason(labels, nil), do: labels

  # A reason is a `Depdep.S3` error rendered with `inspect/1`, so it can be a
  # whole charlist-laden tuple. Useful as a label — "why did this miss?" — and
  # useless at full length: a metresis label value is a stored, grouped-by
  # string, not a log line. Truncated rather than dropped, since the head of one
  # of these carries the distinguishing part.
  defp put_reason(labels, reason) do
    Map.put(labels, "reason", reason |> to_string() |> String.slice(0, 120))
  end

  defp sample(metric, value, labels) when map_size(labels) == 0,
    do: %{"metric" => metric, "value" => value}

  defp sample(metric, value, labels),
    do: %{"metric" => metric, "value" => value, "labels" => labels}

  defp seconds(us), do: Float.round(us / 1_000_000, 6)

  @doc """
  The documents for one run — several when the sample count needs chunking.

  Each carries its own key, so a retry of a chunked run replays every chunk
  rather than only the first.
  """
  def documents(map, labels, direction) do
    map
    |> samples()
    |> Enum.chunk_every(@max_samples)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      {idempotency_key(labels, direction, index), %{"labels" => labels, "samples" => chunk}}
    end)
  end

  @doc """
  Posts the run. `:ok`, `:disabled`, or `{:error, reason}` — never a raise.

  The caller warns on an error and carries on; nothing here may change an exit
  code.
  """
  def post(map, direction, labels \\ nil) do
    case config() do
      :disabled ->
        :disabled

      {:error, reason} ->
        {:error, reason}

      {:ok, cfg} ->
        labels = labels || labels(direction)
        profile = %{key: "depdep", hash: Depdep.Profile.hash()}

        map
        |> documents(labels, direction)
        |> Enum.reduce_while(:ok, fn {key, document}, :ok ->
          case send_with_profile(cfg, key, document, profile) do
            :ok -> {:cont, :ok}
            other -> {:halt, other}
          end
        end)
    end
  end

  # The profile handshake (#86, metresis #243). Every post carries the hash of
  # the profile this depdep ships; an instance that does not hold it for this
  # token answers 428, depdep publishes the document with the same token and
  # retries the post once — two round-trips per version per instance, ever,
  # and the emitter keeps no state. Nothing here loops: a second 428 of any
  # kind is one line and done, and every outcome but a transport failure is
  # `:ok` or `{:warn, _}`, because the numbers are a by-product of work that
  # already succeeded.
  defp send_with_profile(cfg, key, document, profile) do
    case send_document(cfg, key, document, profile) do
      {:precondition, "profile_missing", _body} ->
        case publish_profile(cfg) do
          :ok ->
            case send_document(cfg, key, document, profile) do
              {:precondition, error, body} -> {:warn, precondition(error, body, cfg)}
              other -> other
            end

          {:warn, _} = warn ->
            warn

          error ->
            error
        end

      {:precondition, error, body} ->
        {:warn, precondition(error, body, cfg)}

      other ->
        other
    end
  end

  # What a 428 means for this run. `profile_pending` is only sent for a post
  # that would register a new key, so what was not recorded is exactly that.
  defp precondition("profile_pending", _body, cfg),
    do:
      "metresis: depdep's profile is awaiting approval on #{instance_of(cfg)}; " <>
        "samples for new metrics not recorded until then"

  defp precondition("profile_rejected", body, cfg) do
    reason =
      case field(body, "reason") do
        nil -> ""
        reason -> " — #{reason}"
      end

    "metresis: depdep's profile was rejected on #{instance_of(cfg)}#{reason}"
  end

  defp precondition("profile_missing", _body, cfg),
    do:
      "metresis: #{instance_of(cfg)} still lacks depdep's profile after publishing it — not retried"

  defp precondition(other, _body, cfg),
    do: "metresis: #{instance_of(cfg)} answered 428 #{other}; samples not recorded"

  # POST /profiles with the ingest token: applied at once for a token holding
  # `profile` (201), queued for a member's approval for one holding `propose`
  # (202, or 200 when that hash already waits). Never `adopt`: adoption is the
  # domain's, and the token's own profile is all this needs (§4.7 rung 2).
  defp publish_profile(cfg) do
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(cfg.token)}]

    request =
      {String.to_charlist(cfg.profiles_url), headers, ~c"application/json",
       Depdep.Json.encode(Depdep.Profile.read())}

    case :httpc.request(:post, request, http_options(), body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      {:ok, {{_, 403, _}, _, _}} ->
        {:warn, capability_warning(cfg)}

      {:ok, {{_, 429, _}, _, _}} ->
        {:warn,
         "metresis: #{instance_of(cfg)} has too many unapproved profiles for this token " <>
           "(profile_queue_full); depdep's is not queued, samples not recorded"}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "publishing the profile: #{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp capability_warning(cfg),
    do:
      "metresis: this token cannot publish depdep's profile on #{instance_of(cfg)} " <>
        "(needs the profile or propose capability); metrics land without definitions"

  defp instance_of(cfg), do: String.replace_suffix(cfg.url, "/api/v1/ingest", "")

  # Depdep writes JSON and reads none (`Depdep.Json`); the three fields the
  # handshake reads back are flat strings, and a pattern is enough. A field
  # that is not there is `nil`.
  defp field(body, name) do
    case Regex.run(~r/"#{name}"\s*:\s*"((?:[^"\\]|\\.)*)"/, body) do
      [_, value] -> value
      nil -> nil
    end
  end

  @doc """
  The per-request timeouts, which deliberately are NOT `Depdep.S3`'s.

  Public so a test can assert they stay short. S3's 300 s request timeout is
  right for a 400 MB object and would let an unresponsive metresis add minutes
  to every job in every consumer; passing these per request overrides the global
  options `Depdep.S3.start/0` sets.
  """
  def http_options, do: [connect_timeout: @connect_timeout, timeout: @request_timeout]

  # One ingest post. `:ok`; `{:warn, _}` when the instance accepted the data but
  # the token could not carry a profile (`"profile":"unavailable"`);
  # `{:precondition, error, body}` for a 428; `{:error, _}` otherwise.
  defp send_document(cfg, key, document, profile) do
    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(cfg.token)},
      {~c"idempotency-key", String.to_charlist(key)},
      {~c"metresis-profile", String.to_charlist("#{profile.key} sha256:#{profile.hash}")}
    ]

    request =
      {String.to_charlist(cfg.url), headers, ~c"application/json", Depdep.Json.encode(document)}

    case :httpc.request(:post, request, http_options(), body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        if field(body, "profile") == "unavailable",
          do: {:warn, capability_warning(cfg)},
          else: :ok

      {:ok, {{_, 428, _}, _, body}} ->
        {:precondition, field(body, "error") || "unknown", body}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "#{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
