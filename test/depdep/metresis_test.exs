defmodule Depdep.MetresisTest do
  @moduledoc """
  The ingest post. `async: false` because it reads the environment, which is
  global, and because it opens listening sockets.

  A socket, not a mock — the same choice `Depdep.S3Test` makes for `put/3`, and
  for the same reason: what matters is what goes out on the wire.
  """
  use ExUnit.Case, async: false

  alias Depdep.Metresis
  alias Depdep.Metrics
  alias Depdep.Metrics.{Phase, Unit}

  @vars ~w(DEPDEP_METRESIS DEPDEP_METRESIS_URL DEPDEP_METRESIS_TOKEN CI_PROJECT_PATH CI_COMMIT_SHA
           CI_COMMIT_REF_SLUG CI_PIPELINE_ID CI_JOB_ID CI_JOB_NAME)

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    originals = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(originals, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp run_map do
    unit = %Unit{
      provider: "mix",
      label: "jason",
      bucket: :pulled,
      download_us: 400_000,
      restore_us: 100_000,
      bytes: 2_048
    }

    phase = %Phase{
      provider: "mix",
      direction: :pull,
      span_us: 500_000,
      concurrency: 8,
      tally: %{pulled: 1},
      units: [unit]
    }

    Metrics.to_map([phase], :pull, 900_000)
  end

  # Answers one request with `status`, and hands back what it received.
  defp server(status, opts \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    me = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      received = read_request(socket, "")
      send(me, {:received, received})

      unless opts[:silent] do
        body = ~s({"post_id":1,"accepted":1,"rejected":0})

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\n",
          "content-type: application/json\r\n\r\n",
          body
        ])
      end

      :gen_tcp.close(socket)
    end)

    port
  end

  # A server that answers a scripted sequence — one `{status, body}` per
  # request, in order — and hands back every request it received.
  defp scripted(answers) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    me = self()

    spawn_link(fn ->
      Enum.each(answers, fn {status, body} ->
        {:ok, socket} = :gen_tcp.accept(listen)
        send(me, {:received, read_request(socket, "")})

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\n",
          "content-type: application/json\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
      end)
    end)

    port
  end

  defp received_all(n) do
    for _ <- 1..n do
      receive do
        {:received, raw} -> raw
      after
        3_000 -> flunk("fewer than #{n} requests arrived")
      end
    end
  end

  defp request_line(raw), do: raw |> String.split("\r\n", parts: 2) |> hd()

  defp header(raw, name),
    do: Regex.run(~r/^#{name}: (.*)$/mi, raw) |> List.last() |> String.trim()

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: acc, else: read_request(socket, acc)

      {:error, _} ->
        acc
    end
  end

  defp complete?(acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        case Regex.run(~r/content-length:\s*(\d+)/i, String.downcase(head)) do
          [_, n] -> byte_size(body) >= String.to_integer(n)
          _ -> true
        end

      _ ->
        false
    end
  end

  defp configure(port) do
    System.put_env("DEPDEP_METRESIS_URL", "http://127.0.0.1:#{port}")
    System.put_env("DEPDEP_METRESIS_TOKEN", "mtr_ing_test")
  end

  describe "config/0 — unset means nothing happens" do
    test "both unset is disabled" do
      assert Metresis.config() == :disabled
    end

    test "either one alone is disabled, not a half-configured post" do
      System.put_env("DEPDEP_METRESIS_URL", "http://example")
      assert Metresis.config() == :disabled

      System.delete_env("DEPDEP_METRESIS_URL")
      System.put_env("DEPDEP_METRESIS_TOKEN", "t")
      assert Metresis.config() == :disabled
    end

    test "DEPDEP_METRESIS is the same instance under the shorter name; both names at once is refused" do
      System.put_env("DEPDEP_METRESIS", "http://example/")
      System.put_env("DEPDEP_METRESIS_TOKEN", "t")

      assert {:ok,
              %{
                url: "http://example/api/v1/ingest",
                profiles_url: "http://example/api/v1/profiles",
                token: "t"
              }} =
               Metresis.config()

      System.put_env("DEPDEP_METRESIS_URL", "http://other")
      assert {:error, reason} = Metresis.config()
      assert reason =~ "DEPDEP_METRESIS and DEPDEP_METRESIS_URL are both set"
      System.delete_env("DEPDEP_METRESIS")
      System.delete_env("DEPDEP_METRESIS_URL")
      System.delete_env("DEPDEP_METRESIS_TOKEN")
    end

    test "empty reads as unset, like every other DEPDEP_ variable" do
      System.put_env("DEPDEP_METRESIS_URL", "")
      System.put_env("DEPDEP_METRESIS_TOKEN", "")
      assert Metresis.config() == :disabled
    end

    test "both set gives the ingest path, with a trailing slash tolerated" do
      System.put_env("DEPDEP_METRESIS_TOKEN", "t")
      System.put_env("DEPDEP_METRESIS_URL", "http://m.example/")
      assert {:ok, %{url: "http://m.example/api/v1/ingest"}} = Metresis.config()
    end

    # The regression guard that matters most: nothing set today, so nothing may
    # change for any consumer that ignores this.
    test "post/3 attempts NO connection when unconfigured" do
      _port = server(200)
      assert Metresis.post(run_map(), :pull) == :disabled
      refute_receive {:received, _}, 300
    end
  end

  # spec/01-goals-and-scope.md#failure-not-error. The store and the metrics are
  # both optimisations over work that has already succeeded, so neither may cost
  # a job its result. Nothing else in this suite pointed a post at an endpoint
  # that is not there (#113).
  describe "failure is not an error" do
    @tag verifies: "failure-is-not-an-error"
    test "an endpoint that refuses the connection is an error value, never a raise" do
      configure(closed_port())

      assert {:error, reason} = Metresis.post(run_map(), :pull)
      assert is_binary(reason)
      assert reason != ""
    end
  end

  # A port nothing is listening on: bind one to have the OS choose a free
  # number, then close it. Asking for a refusal by guessing a port number would
  # be a test that fails when somebody happens to be using it.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  describe "labels" do
    test "absent CI variables are omitted rather than filled with a lie" do
      labels = Metresis.labels(:pull)

      assert labels["direction"] == "pull"
      refute Map.has_key?(labels, "project")
      refute Map.has_key?(labels, "pipeline")
    end

    # A run with nothing to key on cannot be idempotent, and two local runs are
    # different events rather than a retry of one.
    test "outside CI a run id is added, so the key is always derivable" do
      labels = Metresis.labels(:pull)
      assert is_binary(labels["run"])
      refute Metresis.labels(:pull)["run"] == labels["run"]
    end

    test "in CI the pipeline and job key it, and no run id is invented" do
      System.put_env("CI_PIPELINE_ID", "1742")
      System.put_env("CI_JOB_ID", "10509")

      refute Map.has_key?(Metresis.labels(:pull), "run")
    end

    test "what GitLab provides is carried" do
      System.put_env("CI_PROJECT_PATH", "dco-tek/metresis")
      System.put_env("CI_PIPELINE_ID", "1742")
      System.put_env("CI_JOB_ID", "10509")

      labels = Metresis.labels(:push)
      assert labels["project"] == "dco-tek/metresis"
      assert labels["pipeline"] == "1742"
      assert labels["direction"] == "push"
      refute Map.has_key?(labels, "commit")
    end
  end

  describe "idempotency_key/3 is pure" do
    @tag verifies: "metresis-idempotency-key"
    test "the same job retried gives the same key" do
      labels = %{"pipeline" => "1742", "job" => "10509"}
      assert Metresis.idempotency_key(labels, :pull, 0) == "depdep-1742-10509-pull-0"
      assert Metresis.idempotency_key(labels, :pull, 0) == "depdep-1742-10509-pull-0"
    end

    # A pull and a push in one job are different events, and §7.2 is explicit
    # that a duplicated tally is silently wrong.
    test "direction and chunk both change it" do
      labels = %{"pipeline" => "1", "job" => "2"}

      refute Metresis.idempotency_key(labels, :pull, 0) ==
               Metresis.idempotency_key(labels, :push, 0)

      refute Metresis.idempotency_key(labels, :pull, 0) ==
               Metresis.idempotency_key(labels, :pull, 1)
    end

    test "outside CI the caller's run value keys it, so it stays a function of its inputs" do
      assert Metresis.idempotency_key(%{"run" => "abc"}, :pull, 0) == "depdep-local-abc-pull-0"
    end
  end

  describe "samples follow spec §4.1" do
    setup do: %{samples: Metresis.samples(run_map())}

    test "durations are seconds, not the microseconds the JSON carries", %{samples: samples} do
      download = Enum.find(samples, &(&1["metric"] == "depdep.download"))
      assert download["value"] == 0.4

      elapsed = Enum.find(samples, &(&1["metric"] == "depdep.elapsed"))
      assert elapsed["value"] == 0.9
    end

    test "the two halves are separate metrics", %{samples: samples} do
      assert Enum.find(samples, &(&1["metric"] == "depdep.download"))["value"] == 0.4
      assert Enum.find(samples, &(&1["metric"] == "depdep.extract"))["value"] == 0.1
    end

    test "labels carry the dimensions rather than encoding them in the key", %{samples: samples} do
      download = Enum.find(samples, &(&1["metric"] == "depdep.download"))
      assert download["labels"] == %{"provider" => "mix", "unit" => "jason", "bucket" => "pulled"}
    end

    test "a tally becomes one sample per bucket", %{samples: samples} do
      units = Enum.filter(samples, &(&1["metric"] == "depdep.units"))
      assert [%{"value" => 1, "labels" => %{"bucket" => "pulled"}}] = units
    end

    test "the concurrency in force is sent, so runs on different runners compare",
         %{samples: samples} do
      assert Enum.find(samples, &(&1["metric"] == "depdep.concurrency"))["value"] == 8
    end

    # §1.3: absence is not zero. A parallelism of 0.0 for a phase that did
    # nothing would be a claim, not a measurement.
    test "a phase that did no work sends no parallelism sample" do
      empty = %Phase{provider: "mix", direction: :pull, span_us: 0, concurrency: 8, units: []}
      samples = Metresis.samples(Metrics.to_map([empty], :pull, 10))
      refute Enum.any?(samples, &(&1["metric"] == "depdep.parallelism"))
    end
  end

  # #86 / metresis #243: the profile travels on the data path. Every post
  # carries the hash; a 428 is answered by publishing and one retry; nothing
  # loops; nothing here can fail the run.
  describe "the profile handshake" do
    @accepted ~s({"post_id":1,"accepted":1,"rejected":0})
    @missing ~s({"error":"profile_missing","key":"depdep","have":null})

    test "every ingest post carries Metresis-Profile with the shipped hash" do
      port = scripted([{200, @accepted}])
      configure(port)
      assert Metresis.post(run_map(), :pull) == :ok

      [raw] = received_all(1)
      assert request_line(raw) =~ "POST /api/v1/ingest"
      assert header(raw, "metresis-profile") == "depdep sha256:" <> Depdep.Profile.hash()
    end

    @tag verifies: "spec/07-metrics-and-profile.md#handshake"
    test "profile_missing: publish with the same token, retry once with the same key, and land" do
      port = scripted([{428, @missing}, {201, ~s({"key":"depdep","hash":"x"})}, {200, @accepted}])
      configure(port)
      assert Metresis.post(run_map(), :pull) == :ok

      [first, publish, retry] = received_all(3)
      assert request_line(first) =~ "POST /api/v1/ingest"
      assert request_line(publish) =~ "POST /api/v1/profiles"
      assert header(publish, "authorization") == "Bearer mtr_ing_test"
      assert publish =~ ~s("key":"depdep")
      refute publish =~ "adopt"
      assert request_line(retry) =~ "POST /api/v1/ingest"
      assert header(retry, "idempotency-key") == header(first, "idempotency-key")
    end

    test "a 202 from a propose-only token is a publish too; the retry then meets the pending rule" do
      port =
        scripted([
          {428, @missing},
          {202, ~s({"status":"pending"})},
          {428, ~s({"error":"profile_pending","key":"depdep"})}
        ])

      configure(port)
      assert {:warn, message} = Metresis.post(run_map(), :pull)
      assert message =~ "awaiting approval on http://127.0.0.1:#{port}"
      assert message =~ "not recorded until then"
      assert length(received_all(3)) == 3
    end

    test "a second profile_missing after publishing is one line, not a loop" do
      port = scripted([{428, @missing}, {201, "{}"}, {428, @missing}])
      configure(port)
      assert {:warn, message} = Metresis.post(run_map(), :pull)
      assert message =~ "still lacks depdep's profile after publishing it — not retried"
      assert length(received_all(3)) == 3
    end

    test "profile_rejected carries the reason and does not publish" do
      port =
        scripted([{428, ~s({"error":"profile_rejected","key":"depdep","reason":"units wrong"})}])

      configure(port)
      assert {:warn, message} = Metresis.post(run_map(), :pull)
      assert message =~ "rejected on http://127.0.0.1:#{port} — units wrong"
      assert length(received_all(1)) == 1
    end

    test "a token with neither capability: data lands, one line about the capability" do
      port =
        scripted([{200, ~s({"post_id":1,"accepted":1,"rejected":0,"profile":"unavailable"})}])

      configure(port)
      assert {:warn, message} = Metresis.post(run_map(), :pull)
      assert message =~ "cannot publish depdep's profile"
      assert message =~ "profile or propose capability"
    end

    test "403 from /profiles is the same capability line; 429 is queue_full" do
      port = scripted([{428, @missing}, {403, ~s({"error":"forbidden"})}])
      configure(port)
      assert {:warn, message} = Metresis.post(run_map(), :pull)
      assert message =~ "profile or propose capability"

      port = scripted([{428, @missing}, {429, ~s({"error":"profile_queue_full"})}])
      configure(port)
      assert {:warn, message} = Metresis.post(run_map(), :pull)
      assert message =~ "profile_queue_full"
    end

    test "an unreachable instance is still an error, not a raise" do
      configure(1)
      assert {:error, _} = Metresis.post(run_map(), :pull)
    end
  end

  # #91/#96: a restored unit Mix would rebuild is a miss with Mix's reason,
  # and the run says how many — every run, zero included, because "0 on every
  # consumer" is the claim the key makes and it has to be visible.
  describe "rebuilt after restore" do
    defp rebuilt(name, why) do
      %Unit{
        provider: "mix",
        label: "app/#{name}",
        bucket: :missing,
        reason: "rebuilt — " <> why,
        rebuilt: true,
        download_us: 10,
        restore_us: 10,
        bytes: 1
      }
    end

    test "the run posts the count, and each such unit's samples carry the reason" do
      units = [
        rebuilt("mint", "the dependency build is outdated"),
        rebuilt("finch", "the dependency build is outdated")
      ]

      phase = %Phase{
        provider: "mix",
        direction: :pull,
        span_us: 50,
        concurrency: 8,
        tally: %{missing: 2},
        units: units
      }

      samples = Metresis.samples(Metrics.to_map([phase], :pull, 100))

      assert %{"value" => 2} =
               Enum.find(samples, &(&1["metric"] == "depdep.rebuilt_after_restore"))

      for sample <- Enum.filter(samples, &(&1["metric"] == "depdep.download")) do
        assert sample["labels"]["bucket"] == "missing"
        assert sample["labels"]["reason"] =~ "rebuilt — the dependency build is outdated"
      end
    end

    test "a clean run posts zero, not nothing", %{} do
      samples = Metresis.samples(run_map())

      assert %{"value" => 0} =
               Enum.find(samples, &(&1["metric"] == "depdep.rebuilt_after_restore"))
    end

    test "the JSON --metrics writes carries the count and the flag" do
      map =
        Metrics.to_map(
          [
            %Phase{
              provider: "mix",
              direction: :pull,
              span_us: 1,
              concurrency: 1,
              units: [rebuilt("mint", "x")]
            }
          ],
          :pull,
          1
        )

      assert map.rebuilt_after_restore == 1
      assert [%{rebuilt: true}] = hd(map.phases).units
    end
  end

  # #101: the unclamped compile the object carries — the estimate a hit
  # avoided. `saved` is this less the transfer and floored at zero, so the two
  # are different facts and a panel that sums transfer with `saved` reports
  # the estimate as transfer whenever the clamp bites.
  describe "the carried compile time" do
    defp hit(extra) do
      struct(
        %Unit{
          provider: "mix",
          label: "app/jason",
          bucket: :pulled,
          download_us: 10,
          restore_us: 10
        },
        extra
      )
    end

    defp samples_for(unit) do
      phase = %Phase{
        provider: "mix",
        direction: :pull,
        span_us: 50,
        concurrency: 8,
        units: [unit]
      }

      Metresis.samples(Metrics.to_map([phase], :pull, 100))
    end

    test "a hit whose object carried one posts it, in seconds, with the unit's labels" do
      [sample] =
        hit(compile_carried_us: 2_500_000, saved_us: 2_480_000)
        |> samples_for()
        |> Enum.filter(&(&1["metric"] == "depdep.compile_carried"))

      assert sample["value"] == 2.5

      assert sample["labels"] == %{
               "provider" => "mix",
               "unit" => "app/jason",
               "bucket" => "pulled"
             }
    end

    test "an object that predates --compile-deps posts nothing, not zero" do
      samples = hit(compile_carried_us: nil, saved_us: nil) |> samples_for()
      refute Enum.any?(samples, &(&1["metric"] == "depdep.compile_carried"))
    end

    # The clamp is why this metric exists: a dependency whose transfer cost
    # more than its compile reports `saved 0`, and the carried number is the
    # only one left that says what compiling it would have cost.
    test "a clamped saved still carries its compile" do
      samples = hit(compile_carried_us: 300_000, saved_us: 0) |> samples_for()

      assert Enum.find(samples, &(&1["metric"] == "depdep.saved"))["value"] == 0.0
      assert Enum.find(samples, &(&1["metric"] == "depdep.compile_carried"))["value"] == 0.3
    end

    test "the --metrics JSON carries the field" do
      map =
        Metrics.to_map(
          [
            %Phase{
              provider: "mix",
              direction: :pull,
              span_us: 1,
              concurrency: 1,
              units: [hit(compile_carried_us: 7)]
            }
          ],
          :pull,
          1
        )

      assert [%{compile_carried_us: 7}] = hd(map.phases).units
    end
  end

  # #59: the number exists only on a unit --compile-deps compiled. Absence is
  # not zero, so every other unit posts no `depdep.compile` at all.
  describe "compile time is posted only where it was measured" do
    defp compile_samples(unit) do
      phase = %Phase{provider: "mix", direction: :pull, span_us: 1, concurrency: 8, units: [unit]}

      [phase]
      |> Metrics.to_map(:pull, 1)
      |> Metresis.samples()
      |> Enum.filter(&(&1["metric"] == "depdep.compile"))
    end

    test "a compiled miss posts seconds and how it was measured" do
      unit = %Unit{
        provider: "mix",
        label: "app/jason",
        bucket: :missing,
        compile_us: 2_500_000,
        compile_exact: true
      }

      assert [sample] = compile_samples(unit)
      assert sample["value"] == 2.5
      assert sample["labels"]["measured"] == "exact"
      assert sample["labels"]["unit"] == "app/jason"

      boundary = %{unit | compile_exact: false}
      assert [%{"labels" => %{"measured" => "boundary"}}] = compile_samples(boundary)
    end

    test "a unit that was not compiled posts nothing" do
      assert compile_samples(%Unit{provider: "mix", label: "app/jason", bucket: :pulled}) == []
    end
  end

  describe "saved time is posted only where a hit knew its compile time" do
    test "per unit, and as a run total" do
      hit = %Unit{provider: "mix", label: "app/jason", bucket: :pulled, saved_us: 2_100_000}
      other = %Unit{provider: "mix", label: "app/decimal", bucket: :pulled}

      phase = %Phase{
        provider: "mix",
        direction: :pull,
        span_us: 1,
        concurrency: 8,
        units: [hit, other]
      }

      samples = [phase] |> Metrics.to_map(:pull, 1) |> Metresis.samples()

      assert [%{"value" => 2.1, "labels" => %{"unit" => "app/jason"}}] =
               Enum.filter(samples, &(&1["metric"] == "depdep.saved"))

      assert [%{"value" => 2.1}] = Enum.filter(samples, &(&1["metric"] == "depdep.saved_total"))
    end

    test "a run where nothing knew posts no total — absence is not zero" do
      unit = %Unit{provider: "mix", label: "app/jason", bucket: :pulled}
      phase = %Phase{provider: "mix", direction: :pull, span_us: 1, concurrency: 8, units: [unit]}
      samples = [phase] |> Metrics.to_map(:pull, 1) |> Metresis.samples()
      refute Enum.any?(samples, &(&1["metric"] in ["depdep.saved", "depdep.saved_total"]))
    end
  end

  describe "a reason is a label, not a log line" do
    test "a long reason is truncated rather than stored whole or dropped" do
      long = String.duplicate("x", 500)
      unit = %Unit{provider: "mix", label: "u", bucket: :missing, reason: long}
      phase = %Phase{provider: "mix", direction: :pull, span_us: 1, concurrency: 8, units: [unit]}

      [sample | _] =
        [phase]
        |> Metrics.to_map(:pull, 1)
        |> Metresis.samples()
        |> Enum.filter(&(&1["metric"] == "depdep.download"))

      reason = sample["labels"]["reason"]
      assert String.length(reason) == 120
      assert String.starts_with?(reason, "xxx")
    end
  end

  describe "documents/3 stays under the cap" do
    test "a small run is one document" do
      assert [{_key, _doc}] = Metresis.documents(run_map(), %{"run" => "r"}, :pull)
    end

    # A 413 rejects the WHOLE body, so an oversized post loses every sample
    # rather than some. Chunking makes that a bounded property, not luck.
    test "a large run is chunked, and every chunk gets its own key" do
      unit = %Unit{provider: "mix", label: "u", bucket: :pulled}
      units = for _ <- 1..4_000, do: unit
      phase = %Phase{provider: "mix", direction: :pull, span_us: 1, concurrency: 8, units: units}
      map = Metrics.to_map([phase], :pull, 1)

      documents = Metresis.documents(map, %{"run" => "r"}, :pull)

      assert length(documents) > 1
      assert Enum.all?(documents, fn {_k, d} -> length(d["samples"]) <= 5_000 end)
      keys = Enum.map(documents, &elem(&1, 0))
      assert keys == Enum.uniq(keys)
    end
  end

  describe "posting, and every way it can fail" do
    test "a 202 posts one document carrying the envelope and the token" do
      port = server(202)
      configure(port)

      assert Metresis.post(run_map(), :pull) == :ok
      assert_receive {:received, request}, 2_000

      assert request =~ "POST /api/v1/ingest"
      assert String.downcase(request) =~ "authorization: bearer mtr_ing_test"
      assert String.downcase(request) =~ "idempotency-key: depdep-"
      assert request =~ ~s("metric":"depdep.download")
      assert request =~ ~s("samples")
    end

    test "a 401 is an error to report, not an exception" do
      configure(server(401))
      assert {:error, message} = Metresis.post(run_map(), :pull)
      assert message =~ "401"
    end

    test "a 413 — the body-too-large case — is reported with its status" do
      configure(server(413))
      assert {:error, message} = Metresis.post(run_map(), :pull)
      assert message =~ "413"
    end

    test "a 500 is reported" do
      configure(server(500))
      assert {:error, message} = Metresis.post(run_map(), :pull)
      assert message =~ "500"
    end

    test "a refused connection is reported rather than raised" do
      System.put_env("DEPDEP_METRESIS_URL", "http://127.0.0.1:9")
      System.put_env("DEPDEP_METRESIS_TOKEN", "t")

      assert {:error, message} = Metresis.post(run_map(), :pull)
      assert message =~ "econnrefused" or message =~ "failed_connect"
    end
  end

  describe "timeouts are its own, and short" do
    # `Depdep.S3` gives httpc 300 s, which is right for a 400 MB object and would
    # let an unresponsive metresis add minutes to every job in every consumer.
    test "the ingest timeouts are far below S3's request timeout" do
      options = Metresis.http_options()

      assert options[:connect_timeout] <= 10_000
      assert options[:timeout] <= 30_000
      assert options[:timeout] < 300_000
    end
  end
end
