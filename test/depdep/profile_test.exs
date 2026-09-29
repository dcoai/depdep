defmodule Depdep.ProfileTest do
  use ExUnit.Case, async: false

  alias Depdep.Profile

  test "the shipped document reads, is a literal with string keys, and encodes as JSON" do
    document = Profile.read()
    assert document["key"] == "depdep"
    assert document["version"] == 1
    assert Enum.all?(Map.keys(document), &is_binary/1)

    json = Depdep.Json.encode(document)
    assert json =~ ~s("key":"depdep")
    assert json =~ ~s("depdep.saved_total")
  end

  # A hex install ships `lib/` and `priv/` and nothing else, so the document
  # has to be found through the application's priv dir. `__DIR__` was how the
  # first version found it (#73) — a path into a source tree the package does
  # not carry.
  test "the document lives in the application's priv/, not in the source tree" do
    priv = :code.priv_dir(:depdep) |> to_string()
    assert String.starts_with?(Profile.path(), priv)
    assert File.regular?(Profile.path())
    refute File.read!("lib/depdep/profile.ex") =~ "__DIR__"
  end

  @tag verifies: "profile-holds-the-code"
  test "the shipped document agrees with the code, both ways" do
    assert Profile.check() == :ok
  end

  # The point of the check is that either side can drift and be caught.
  test "a metric the code emits but the document drops is named" do
    document =
      Profile.read()
      |> Map.update!("metrics", &Enum.reject(&1, fn m -> m["key"] == "depdep.saved" end))

    assert {:error, problems} = Profile.check(document)
    assert problems == ["emitted but not in the profile: metric depdep.saved"]
  end

  test "a metric the document names but the code never emits is named" do
    stray = %{
      "key" => "depdep.warmth",
      "name" => "Warmth",
      "type" => "gauge",
      "quantity" => "number",
      "polarity" => "neutral"
    }

    document = Profile.read() |> Map.update!("metrics", &[stray | &1])

    assert {:error, ["in the profile but never emitted: metric depdep.warmth"]} =
             Profile.check(document)
  end

  test "a label key either side lacks is named" do
    document =
      Profile.read()
      |> Map.update!("label_keys", &Enum.reject(&1, fn k -> k["key"] == "measured" end))

    assert {:error, ["emitted but not in the profile: label measured"]} = Profile.check(document)
  end

  # Every bucket `Report.buckets/1` can print, in either direction, must be an
  # expected value — a fifth bucket added without touching the profile (#62's
  # shape) is exactly the drift this exists to catch.
  test "every bucket value the code can report is expected by the profile, and no other" do
    document = Profile.read()

    trimmed =
      Map.update!(document, "label_keys", fn keys ->
        Enum.map(keys, fn
          %{"key" => "bucket"} = k ->
            Map.update!(k, "expected_values", &List.delete(&1, "not_for_env"))

          k ->
            k
        end)
      end)

    assert {:error, ["bucket value not expected by the profile not_for_env"]} =
             Profile.check(trimmed)

    extra =
      Map.update!(document, "label_keys", fn keys ->
        Enum.map(keys, fn
          %{"key" => "bucket"} = k -> Map.update!(k, "expected_values", &["vanished" | &1])
          k -> k
        end)
      end)

    assert {:error, ["profile expects a bucket value the code has not vanished"]} =
             Profile.check(extra)
  end

  # #86: the hash every ingest post carries. Canonical JSON — sorted keys,
  # compact — so the same document hashes the same wherever it is computed,
  # which is what metresis compares against.
  describe "hash/0" do
    test "is sha256 of the canonical JSON, hex, and stable" do
      assert Profile.hash() =~ ~r/^[0-9a-f]{64}$/
      assert Profile.hash() == Profile.hash()

      assert Profile.hash() ==
               :crypto.hash(:sha256, Depdep.Json.encode(Profile.read()))
               |> Base.encode16(case: :lower)
    end

    test "key order does not matter; one changed description does" do
      document = Profile.read()
      reordered = document |> Enum.reverse() |> Map.new()
      assert Profile.hash(reordered) == Profile.hash(document)

      changed =
        Map.update!(document, "metrics", fn [m | rest] ->
          [Map.put(m, "description", "x") | rest]
        end)

      refute Profile.hash(changed) == Profile.hash(document)
    end
  end

  # #100: the drift a local check cannot see. On cn2 the four compile-timing
  # metrics were present and catalogued as bare `number`s — a hash comparison
  # would have said "differs" and stopped there.
  describe "compare/3 — what this ships against what an instance holds" do
    defp theirs(metrics, extra \\ %{}) do
      Map.merge(
        %{"key" => "depdep", "version" => 1, "metrics" => metrics, "label_keys" => []},
        extra
      )
    end

    defp mine(metrics, extra \\ %{}) do
      theirs(metrics, extra)
    end

    defp metric(key, fields \\ %{}) do
      Map.merge(
        %{
          "key" => key,
          "type" => "gauge",
          "quantity" => "duration",
          "unit" => "s",
          "polarity" => "neutral"
        },
        fields
      )
    end

    test "agreement is an empty list" do
      document = mine([metric("depdep.saved")])
      assert Profile.compare(document, document, "http://m") == []
    end

    test "a metric the instance lacks is named" do
      assert ["in the profile but not on http://m: metric depdep.compile_carried"] =
               Profile.compare(mine([metric("depdep.compile_carried")]), theirs([]), "http://m")
    end

    test "a metric only the instance has is named too — the profile may have dropped it" do
      assert ["on http://m but not in the profile: metric depdep.legacy"] =
               Profile.compare(mine([]), theirs([metric("depdep.legacy")]), "http://m")
    end

    # The case that actually happened: present on both sides, cataloged bare.
    test "a metric present on both sides but catalogued differently names the field" do
      provisional = metric("depdep.saved", %{"quantity" => "number", "unit" => nil})

      assert [quantity, unit] =
               Profile.compare(mine([metric("depdep.saved")]), theirs([provisional]), "http://m")

      assert quantity == ~s(metric depdep.saved: quantity "number" on http://m, "duration" here)
      assert unit == ~s(metric depdep.saved: unit nil on http://m, "s" here)
    end

    test "a differing version is reported, and an absent profile is the finding" do
      assert [~s(version 2 on http://m, 1 here)] =
               Profile.compare(mine([]), theirs([], %{"version" => 2}), "http://m")

      assert ["no depdep profile on http://m at all"] =
               Profile.compare(mine([]), :absent, "http://m")
    end

    test "the shipped document compares clean against itself" do
      assert Profile.compare(Profile.read(), Profile.read(), "http://m") == []
    end
  end

  # The task half: one GET, and every answer that is not a difference must
  # leave the pipeline alone.
  describe "mix depdep.profile check --instance" do
    setup do
      saved =
        {System.get_env("DEPDEP_METRESIS"), System.get_env("DEPDEP_METRESIS_TOKEN"),
         System.get_env("DEPDEP_METRESIS_URL")}

      on_exit(fn ->
        {m, t, u} = saved

        for {name, value} <- [
              {"DEPDEP_METRESIS", m},
              {"DEPDEP_METRESIS_TOKEN", t},
              {"DEPDEP_METRESIS_URL", u}
            ] do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      System.delete_env("DEPDEP_METRESIS_URL")
      :ok
    end

    defp answering(status, body) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
      {:ok, port} = :inet.port(listen)
      me = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        send(me, {:asked, recv_request(socket, "")})

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\n",
          "content-type: application/json\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
      end)

      System.put_env("DEPDEP_METRESIS", "http://127.0.0.1:#{port}")
      System.put_env("DEPDEP_METRESIS_TOKEN", "mtr_ing_test")
      port
    end

    defp recv_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} ->
          acc = acc <> data
          if String.contains?(acc, "\r\n\r\n"), do: acc, else: recv_request(socket, acc)

        {:error, _} ->
          acc
      end
    end

    defp asked do
      receive do
        {:asked, raw} -> raw
      after
        3_000 -> flunk("the instance was never asked")
      end
    end

    test "an instance holding this document is green, and is asked with the ingest token" do
      port = answering(200, Depdep.Json.encode(Profile.read()))

      assert Mix.Tasks.Depdep.Profile.run(["check", "--instance"]) == :ok

      raw = asked()
      assert raw =~ "GET /api/v1/profiles/depdep HTTP/1.1"
      assert raw =~ "authorization: Bearer mtr_ing_test"
      assert raw =~ "127.0.0.1:#{port}"
    end

    test "a difference fails, naming it" do
      stripped =
        Map.update!(
          Profile.read(),
          "metrics",
          &Enum.reject(&1, fn m -> m["key"] == "depdep.saved" end)
        )

      answering(200, Depdep.Json.encode(stripped))

      assert_raise Mix.Error, ~r/1 difference\(s\)/, fn ->
        Mix.Tasks.Depdep.Profile.run(["check", "--instance"])
      end
    end

    test "an instance with no depdep profile at all fails" do
      answering(404, ~s({"errors":[{"path":"key","error":"not a profile"}]}))

      assert_raise Mix.Error, ~r/difference/, fn ->
        Mix.Tasks.Depdep.Profile.run(["check", "--instance"])
      end
    end

    # The rule this check lives by: it may report, it may not break a build
    # for a reason that is not about the profile.
    test "an unreachable instance is a note and exit 0" do
      System.put_env("DEPDEP_METRESIS", "http://127.0.0.1:1")
      System.put_env("DEPDEP_METRESIS_TOKEN", "t")
      assert Mix.Tasks.Depdep.Profile.run(["check", "--instance"]) == :ok
    end

    test "no metresis configured is a note and exit 0" do
      System.delete_env("DEPDEP_METRESIS")
      System.delete_env("DEPDEP_METRESIS_TOKEN")
      assert Mix.Tasks.Depdep.Profile.run(["check", "--instance"]) == :ok
    end
  end

  test "mix depdep.profile publish is gone: a usage error, not a silent nothing" do
    assert_raise Mix.Error, ~r/usage: mix depdep.profile check/, fn ->
      Mix.Tasks.Depdep.Profile.run(["publish"])
    end
  end

  test "the metrics' enumerations are ones metresis accepts" do
    for metric <- Profile.read()["metrics"] do
      assert metric["type"] == "gauge"
      assert metric["quantity"] in ~w(duration bytes number count)
      assert metric["polarity"] in ~w(higher_better higher_worse neutral)
      assert is_binary(metric["description"]) and metric["description"] != ""
    end

    for key <- Profile.read()["label_keys"], do: assert(key["role"] in ~w(dimension annotation))
  end
end
