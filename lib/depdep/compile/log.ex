defmodule Depdep.Compile.Log do
  @moduledoc """
  Per-dependency compile time, read off the lines Mix already prints.

  Mix times every task it runs — including the `mix compile` it runs inside
  each dependency — and prints the number under `MIX_DEBUG=1`. But the
  *boundaries* are printed always: `==> jason` when Mix enters a dependency,
  `Generated jason app` when its compile is done, and `===> Compiling telemetry`
  from rebar3, which prints no timing at all. So depdep timestamps each line as
  it arrives and takes the span between boundaries, with no debug output and
  nothing compiled twice (#59).

  ## Two kinds of number

  A Mix unit's span runs from `==> name` to `Generated name app` — the whole of
  Mix's own compile of it, which is exact. A rebar3 unit's span runs from
  `===> Compiling name` to whatever boundary comes next, since rebar3 marks no
  end; that includes rebar's own startup and is `:boundary` rather than
  `:exact`. Both are real wall-clock the hit will save; only one is
  attributable to the nearest millisecond.

  ## Partitions

  Under `MIX_OS_DEPS_COMPILE_PARTITION_COUNT`, Mix relays each child's lines
  prefixed by its partition number (`2> ==> jason`), and closes with
  `-- mix deps.partition 2 compiled jason`. One current unit is kept per
  partition, so interleaving is per line and never confuses two dependencies.

  Pure over `{microseconds, line}` pairs, which is what makes it testable
  against captured transcripts.
  """

  @type span :: {non_neg_integer(), :exact | :boundary}

  @doc """
  `%{name => {us, :exact | :boundary}}` for every dependency the log shows
  compiling.

  Any unit still open when the log ends is closed at the last timestamp: a
  compile whose final line is a warning rather than `Generated` is measured to
  the end, not lost.
  """
  def attribute(stamped_lines) do
    {open, done, last} =
      Enum.reduce(stamped_lines, {%{}, %{}, 0}, fn {us, line}, {open, done, _} ->
        {partition, text} = split_partition(line)
        {open, done} = step(text, partition, us, open, done)
        {open, done, us}
      end)

    # The end of the log is an inferred boundary like any other, whatever the
    # unit's own kind: nothing printed says the compile finished there.
    Enum.reduce(open, done, fn {_partition, {name, start, _kind}}, done ->
      close(done, name, start, last, :boundary)
    end)
  end

  # Only a partition's own lines carry its prefix; the parent's `-- … compiled`
  # closers name the partition in the text and are handled in `step/5`.
  defp split_partition(line) do
    case Regex.run(~r/^(\d+)> (.*)$/, line) do
      [_, n, rest] -> {String.to_integer(n), rest}
      nil -> {0, line}
    end
  end

  defp step(text, partition, us, open, done) do
    cond do
      match = Regex.run(~r/^==> (\S+)$/, text) ->
        [_, name] = match
        {open, done} = close_open(open, done, partition, us)
        {Map.put(open, partition, {name, us, :exact}), done}

      match = Regex.run(~r/^Generated (\S+) app$/, text) ->
        [_, name] = match

        case Map.get(open, partition) do
          {^name, start, kind} ->
            {Map.delete(open, partition), close(done, name, start, us, kind)}

          _ ->
            {open, done}
        end

      match = Regex.run(~r/^===> Compiling (\S+)$/, text) ->
        [_, name] = match
        {open, done} = close_open(open, done, partition, us)
        {Map.put(open, partition, {name, us, :boundary}), done}

      match = Regex.run(~r/^-- mix deps\.partition (\d+) compiled (\S+)$/, text) ->
        [_, n, name] = match
        partition = String.to_integer(n)

        case Map.get(open, partition) do
          {^name, start, kind} ->
            {Map.delete(open, partition), close(done, name, start, us, kind)}

          _ ->
            {open, done}
        end

      true ->
        {open, done}
    end
  end

  # A new boundary in a partition ends whatever was open there. For a Mix unit
  # that means its `Generated` line never came — it stays `:exact` in kind but
  # the reader should know the end was inferred, so it is demoted.
  defp close_open(open, done, partition, us) do
    case Map.pop(open, partition) do
      {nil, open} -> {open, done}
      {{name, start, _kind}, open} -> {open, close(done, name, start, us, :boundary)}
    end
  end

  defp close(done, name, start, stop, kind), do: Map.put(done, name, {stop - start, kind})
end
