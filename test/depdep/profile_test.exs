defmodule Depdep.ProfileTest do
  use ExUnit.Case, async: true

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
