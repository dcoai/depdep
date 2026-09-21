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
      assert Metresis.config() == {:ok, %{url: "http://example/api/v1/ingest", token: "t"}}

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
