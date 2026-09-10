defmodule Depdep.JsonTest do
  use ExUnit.Case, async: true

  alias Depdep.Json

  describe "scalars" do
    test "the three atoms that are not strings" do
      assert Json.encode(nil) == "null"
      assert Json.encode(true) == "true"
      assert Json.encode(false) == "false"
    end

    test "any other atom is a string, so a bucket name encodes as its name" do
      assert Json.encode(:pulled) == ~s("pulled")
    end

    test "integers and floats" do
      assert Json.encode(0) == "0"
      assert Json.encode(-17) == "-17"
      assert Json.encode(1.5) == "1.5"
    end
  end

  describe "strings are escaped, because a unit label can contain anything" do
    test "quotes and backslashes" do
      assert Json.encode(~S(a"b)) == ~S("a\"b")
      assert Json.encode(~S(a\b)) == ~S("a\\b")
    end

    test "the named control characters" do
      assert Json.encode("a\nb") == ~S("a\nb")
      assert Json.encode("a\tb") == ~S("a\tb")
      assert Json.encode("a\rb") == ~S("a\rb")
    end

    # A raw control character produces a document nothing can parse, which is
    # worse than an ugly one.
    test "any other control character becomes a unicode escape" do
      assert Json.encode(<<0x01>>) == "\"\\u0001\""
      assert Json.encode(<<0x1F>>) == "\"\\u001f\""
    end

    test "non-ASCII is passed through as UTF-8" do
      assert Json.encode("café") == ~s("café")
    end
  end

  describe "containers" do
    test "lists" do
      assert Json.encode([]) == "[]"
      assert Json.encode([1, "a", nil]) == ~s([1,"a",null])
    end

    # Output is a function of input, so diffing two runs is meaningful rather
    # than dependent on map ordering.
    test "map keys are sorted, and atom keys encode as strings" do
      assert Json.encode(%{b: 2, a: 1}) == ~s({"a":1,"b":2})
      assert Json.encode(%{"z" => 1, "a" => 2}) == ~s({"a":2,"z":1})
    end

    test "a struct encodes as its fields, without __struct__" do
      encoded = Json.encode(%Depdep.Metrics.Unit{label: "jason", bytes: 12})
      refute encoded =~ "__struct__"
      assert encoded =~ ~s("label":"jason")
      assert encoded =~ ~s("bytes":12)
    end

    test "nesting" do
      assert Json.encode(%{a: [%{b: 1}]}) == ~s({"a":[{"b":1}]})
    end
  end
end
