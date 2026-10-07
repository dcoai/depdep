defmodule Depdep.ProfileTest do
  use ExUnit.Case, async: false

  alias Depdep.Profile

  test "the shipped document reads, is a literal with string keys, and encodes as JSON" do
    document = Profile.read()
    assert document["key"] == "depdep"
    assert Enum.all?(Map.keys(document), &is_binary/1)

    # The version is an integer, and that is all this test says about it. It used to assert
    # `== 1`, which is why nothing complained while the document grew by five metrics and
    # three panels: a literal pins the value rather than the property, so it stayed green on
    # a version that no longer described what shipped (#171, for #111). What the version has
    # to satisfy is a RELATIONSHIP to the content, and that is asserted against the golden.
    assert is_integer(document["version"])

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
  @tag verifies: "spec/09-cli.md#profile-task"
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

  # #171, for #111. The version was 1 while the document had grown by five metrics and three
  # panels, and `cn2` held version 2 with the OLDER vocabulary — newer by number, older by
  # content, so metresis's one signal was inverted rather than merely absent. A bump alone
  # is one character that drifts again; the guard is the deliverable.
  describe "content_hash/1 — what the version is guarded against" do
    @tag verifies: "profile-version-is-bound-to-content"
    test "excludes the version, where hash/0 includes it" do
      document = Profile.read()
      bumped = Map.put(document, "version", 99)

      # The whole point: the wire hash moves on a bump, so it cannot tell a bump apart from
      # a change. The content hash does not move, so it can.
      refute Profile.hash(bumped) == Profile.hash(document)
      assert Profile.content_hash(bumped) == Profile.content_hash(document)
    end

    test "moves when anything else moves, including prose" do
      document = Profile.read()

      assert Profile.content_hash(Map.put(document, "guidance", "different")) !=
               Profile.content_hash(document)

      assert Profile.content_hash(document) =~ ~r/^[0-9a-f]{64}$/
    end
  end

  # These three were cited by spec/07-metrics-and-profile.md#profile and exercised only
  # THROUGH check/1, so no test called them and their claims could never be reviewed — the
  # same hole #159 found across the spec, and the same one plan/3 had (#169). Called directly
  # here, asserting what the section says each one answers.
  describe "the two lists the section names" do
    test "vocabulary/1 lists what the document defines" do
      v = Profile.vocabulary()

      assert MapSet.member?(v.metrics, "depdep.saved_total")
      assert MapSet.member?(v.label_keys, "project")
      assert MapSet.member?(v.bucket_values, "pulled")

      # A document's own names, not the code's: handed a narrower document it says so.
      narrowed =
        Profile.read()
        |> Map.put("metrics", [%{"key" => "depdep.elapsed"}])
        |> Map.put("label_keys", [%{"key" => "project"}])

      assert Profile.vocabulary(narrowed).metrics == MapSet.new(["depdep.elapsed"])
    end

    test "emitted/0 lists what the code posts, which is what check/1 compares against" do
      e = Profile.emitted()

      assert MapSet.member?(e.metrics, "depdep.elapsed")
      assert MapSet.member?(e.label_keys, "project")
    end
  end

  describe "published/1 — what the golden prints" do
    test "reads the panels from the dashboard's layout, where they actually live" do
      p = Profile.published()

      # The first version of this looked for "panels" directly under each dashboard and
      # found none, which would have published an empty list and had the golden record
      # that as correct. The nesting is layout -> panels.
      assert length(p.panels) == 9
      assert "Units by bucket" in p.panels

      assert length(p.metrics) == 14

      assert {"depdep.saved_total", "s", "lower_worse"} in p.metrics or
               Enum.any?(p.metrics, &(elem(&1, 0) == "depdep.saved_total"))
    end

    test "golden_path/0 names the committed file" do
      assert Profile.golden_path() == "PROFILE.md"
    end
  end

  describe "the golden, and the two ways it fails" do
    test "the committed golden matches the shipped profile" do
      assert Profile.golden_check() == :ok,
             "PROFILE.md has drifted — run `mix depdep.profile golden --write`"
    end

    test "the version is past the 2 the instance held, so a publish reads as an update" do
      assert Map.fetch!(Profile.read(), "version") > 2
    end

    # Changing the document without bumping is the defect this exists to stop, and the
    # message has to name WHAT changed — a check that says only "stale" makes a reader diff
    # the file by hand.
    test "a changed vocabulary with a standing version fails, naming the change" do
      changed =
        Map.update!(Profile.read(), "metrics", fn metrics ->
          [%{"key" => "depdep.invented", "unit" => "s", "polarity" => "neutral"} | metrics]
        end)

      assert {:drift, lines} = Profile.golden_check(changed)
      assert Enum.any?(lines, &(&1 =~ "is still"))
      assert Enum.any?(lines, &(&1 =~ "metric added: depdep.invented"))
    end

    test "a removed panel is named too, not only an added one" do
      changed =
        Map.update!(Profile.read(), "dashboards", fn [dashboard | rest] ->
          [update_in(dashboard, ["layout", "panels"], &tl(&1)) | rest]
        end)

      assert {:drift, lines} = Profile.golden_check(changed)
      assert Enum.any?(lines, &(&1 =~ "panel gone:"))
    end

    # A bump means something, so a bump that announces nothing is also a failure.
    test "a bumped version with the document unchanged fails" do
      bumped = Map.update!(Profile.read(), "version", &(&1 + 1))

      assert {:drift, lines} = Profile.golden_check(bumped)
      assert Enum.any?(lines, &(&1 =~ "announces nothing"))
    end

    # Prose is a real update — metresis shows `guidance` to a person deciding whether to
    # adopt — so it is guarded like anything else, with no vocabulary line to report.
    test "a prose-only change still needs a bump" do
      changed = Map.put(Profile.read(), "guidance", "rewritten")

      assert {:drift, lines} = Profile.golden_check(changed)
      assert Enum.any?(lines, &(&1 =~ "is still"))
    end

    test "golden/1 is a pure function of the document" do
      document = Profile.read()
      assert Profile.golden(document) == Profile.golden(document)
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
