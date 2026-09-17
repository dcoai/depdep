defmodule Depdep.Compile.LogTest do
  @moduledoc """
  Transcripts captured from Elixir 1.20.4 / OTP 29, one timestamp per line.
  The timestamps are chosen so every span is a distinct, checkable number.
  """
  use ExUnit.Case, async: true

  alias Depdep.Compile.Log

  defp stamped(lines), do: Enum.with_index(lines, fn line, i -> {i * 1_000, line} end)

  test "a serial mix compile: ==> to Generated, exact" do
    log =
      stamped([
        "==> nimble_options",
        "Compiling 3 files (.ex)",
        "Generated nimble_options app",
        "==> jason",
        "Compiling 10 files (.ex)",
        "Generated jason app"
      ])

    assert Log.attribute(log) == %{
             "nimble_options" => {2_000, :exact},
             "jason" => {2_000, :exact}
           }
  end

  # rebar3 marks no end, so its span runs to the next boundary — here the
  # parent project being re-entered — and is called what it is.
  test "a rebar3 unit is measured to the next boundary, and marked so" do
    log =
      stamped([
        "===> Analyzing applications...",
        "===> Compiling telemetry",
        "==> ct",
        "Generated ct app"
      ])

    assert Log.attribute(log) == %{"telemetry" => {1_000, :boundary}, "ct" => {1_000, :exact}}
  end

  # Verified: Mix relays each child's lines with its partition number, and
  # closes each unit from the parent with no prefix. Two units interleaved
  # line by line must not bleed into each other.
  test "partitioned: one current unit per partition, closers from the parent" do
    log =
      stamped([
        "mix deps.compile running across 2 OS processes",
        "-- Sending nimble_options to mix deps.partition 2",
        "-- Sending jason to mix deps.partition 1",
        "2> ==> nimble_options",
        "1> ==> jason",
        "2> Compiling 3 files (.ex)",
        "1> Compiling 10 files (.ex)",
        "2> Generated nimble_options app",
        "-- mix deps.partition 2 compiled nimble_options",
        "-- Sending telemetry to mix deps.partition 2",
        "2> ===> Compiling telemetry",
        "1> Generated jason app",
        "-- mix deps.partition 1 compiled jason",
        "-- mix deps.partition 2 compiled telemetry"
      ])

    assert Log.attribute(log) == %{
             "nimble_options" => {4_000, :exact},
             "jason" => {7_000, :exact},
             "telemetry" => {3_000, :boundary}
           }
  end

  # A compile that fails prints no `Generated`; the log simply ends, or the
  # next unit begins. Either way the number is kept and its kind says the end
  # was inferred.
  test "a unit with no closing line is closed at the end, or by the next boundary" do
    at_end = stamped(["==> broken", "** (CompileError) lib/x.ex:1: oops"])
    assert Log.attribute(at_end) == %{"broken" => {1_000, :boundary}}

    by_next = stamped(["==> broken", "warning: something", "==> other", "Generated other app"])
    assert Log.attribute(by_next) == %{"broken" => {2_000, :boundary}, "other" => {1_000, :exact}}
  end

  test "a Generated line for a unit that was not opened is ignored" do
    assert Log.attribute(stamped(["Generated stray app"])) == %{}
  end

  test "an empty log is an empty answer" do
    assert Log.attribute([]) == %{}
  end
end
