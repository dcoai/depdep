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

  # §7.11's emitter side: one POST, admin bearer, the document plus `adopt`.
  describe "publish/4" do
    defp server(status, body) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
      {:ok, port} = :inet.port(listen)
      me = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        received = read_request(socket, "")
        send(me, {:received, received})

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\n",
          "content-type: application/json\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
      end)

      port
    end

    defp read_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} ->
          acc = acc <> data

          case String.split(acc, "\r\n\r\n", parts: 2) do
            [head, body] ->
              [_, len] = Regex.run(~r/content-length: (\d+)/i, head)

              if byte_size(body) >= String.to_integer(len),
                do: acc,
                else: read_request(socket, acc)

            _ ->
              read_request(socket, acc)
          end

        {:error, _} ->
          acc
      end
    end

    defp received do
      receive do
        {:received, raw} -> raw
      after
        3_000 -> flunk("the server received no request")
      end
    end

    test "POSTs the document with adopt: true and the admin bearer" do
      port = server(201, ~s({"key":"depdep","version":1,"adopted":true}))
      url = "http://127.0.0.1:#{port}/"

      assert {:ok, answer} =
               Profile.publish(%{"key" => "depdep", "name" => "Depdep"}, url, "mtr_adm_x")

      assert answer =~ "adopted"

      raw = received()
      [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
      assert head =~ "POST /api/v1/profiles HTTP/1.1"
      assert head =~ "authorization: Bearer mtr_adm_x"
      assert head =~ "content-type: application/json"
      assert body =~ ~s("adopt":true)
      assert body =~ ~s("key":"depdep")
    end

    test "adopt: false leaves the flag out" do
      port = server(200, "{}")

      assert {:ok, _} =
               Profile.publish(%{"key" => "depdep"}, "http://127.0.0.1:#{port}", "t",
                 adopt: false
               )

      refute received() =~ "adopt"
    end

    test "a refusal carries the server's answer" do
      port = server(422, ~s({"errors":["metric depdep.warmth: unknown quantity"]}))

      assert {:error, message} =
               Profile.publish(%{"key" => "depdep"}, "http://127.0.0.1:#{port}", "t")

      assert message =~ "422"
      assert message =~ "depdep.warmth"
    end

    test "an unreachable instance is an error, not a hang or a raise" do
      assert {:error, _} = Profile.publish(%{"key" => "depdep"}, "http://127.0.0.1:1", "t")
    end
  end

  # Doing nothing quietly is how a domain stays on provisional definitions;
  # the task is only run where publishing is intended, so a missing variable
  # stops it and names itself.
  test "mix depdep.profile publish refuses to run without its variables" do
    System.delete_env("DEPDEP_METRESIS_URL")
    System.delete_env("DEPDEP_METRESIS_ADMIN_TOKEN")

    assert_raise Mix.Error, ~r/DEPDEP_METRESIS_URL is not set/, fn ->
      Mix.Tasks.Depdep.Profile.run(["publish"])
    end

    System.put_env("DEPDEP_METRESIS_URL", "http://127.0.0.1:1")

    assert_raise Mix.Error, ~r/DEPDEP_METRESIS_ADMIN_TOKEN is not set/, fn ->
      Mix.Tasks.Depdep.Profile.run(["publish"])
    end

    System.delete_env("DEPDEP_METRESIS_URL")
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
