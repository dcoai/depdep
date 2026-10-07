defmodule Depdep.RestoreCheck.Manifest do
  @moduledoc """
  What a restored build's Mix manifest recorded, against what Mix expected.

  `Depdep.RestoreCheck` reports *that* Mix would rebuild a restored unit, in Mix's
  own words. Mix's words for the commonest case are "the dependency build is
  outdated", and **that one sentence covers two different causes** — the recorded
  lock entry differing from the current one, and the manifest not being readable
  at all. Neither says which input the key missed, which is the only question
  anyone asks when `depdep.rebuilt_after_restore` moves (#134).

  This module answers it. `Mix.Dep.Loader.validate_manifest/1` reads
  `<opts[:build]>/.mix/compile.elixir_scm` and compares three things in order: the
  Elixir and OTP pair, the SCM module, then the lock entry. `compare/2` does the
  same comparison and names, for the lock, **the index of the first differing
  tuple element** — which is the point, because that index maps to a cause: 2 or 3
  is the version or checksum (both of which the key already captures, so a
  mismatch there would be a different bug), 5 is the dependency list, 6 the repo,
  7 the outer checksum.

  ## Read directly, not through Mix

  `Mix.Dep.ElixirSCM` is `@moduledoc false`, and its `read/1` wraps the decode in a
  `rescue` that answers `{:ok, {"1.0.0", ~c"17"}, nil, nil}` for a term it cannot
  match — inventing a plausible-looking answer for unreadable data, which is the
  bug-hiding this project refuses anywhere. `read/1` here says `:unreadable`
  instead, and `Depdep.Archive` already relies on this file's shape, so nothing new
  is coupled.

  `compare/2` is pure, so every verdict is exercised without a filesystem.
  """

  @doc """
  The `compile_env` entries a dependency's build recorded, from its `.app`.

  `{:ok, entries}`, or `:absent` when there is no `.app` or it records none, or
  `:unreadable` when the file is not the term Mix writes. Mix conflates the last two
  (`Mix.AppLoader.read_app/2` answers `:invalid` either way for a bad file and
  `:missing` for none), and they have different causes — the same distinction
  `read/1` makes for the compile manifest.

  Read through `Mix.AppLoader.read_app/2` rather than by parsing the file here: it is
  public, it is what Mix itself reads with, and it answers `:invalid` rather than
  inventing a plausible term. That is the opposite of `Mix.Dep.ElixirSCM`, which
  `read/1` avoids for exactly that reason.

  An entry is `{app, [key | path], compile_return}`, where `compile_return` is the
  `{:ok, value}` or `:error` the dependency saw at build time.
  """
  def compile_env(build, app) when is_binary(build) and is_atom(app) do
    path = Path.join([build, "ebin", "#{app}.app"])

    case Mix.AppLoader.read_app(app, path) do
      {:ok, properties} ->
        case List.keyfind(properties, :compile_env, 0) do
          {:compile_env, [_ | _] = entries} -> {:ok, entries}
          _ -> :absent
        end

      :invalid ->
        :unreadable

      :missing ->
        :absent
    end
  end

  @doc """
  The entries whose recorded value disagrees with the application env **right now**.

  `[{app, key_path, recorded, current}]`, empty when every entry agrees. The
  comparison is `Config.Provider.valid_compile_env?/1`'s, one entry at a time so the
  differing one can be named: the recorded `compile_return` against
  `Application.fetch_env/2` traversed down the key path.

  **It must be called while the member's configuration is loaded** — which is during
  the converge, not after it (`Depdep.Deps.converged/3`'s `compile_env:` option).
  Called later it would compare against an empty env and report every entry as
  differing, which is the defect #161 fixed wearing a diagnostic's clothes.
  """
  def compile_env_differences(entries) do
    for {app, [key | path], recorded} <- entries,
        current = traverse(Application.fetch_env(app, key), path),
        current != recorded do
      {app, [key | path], recorded, current}
    end
  end

  # `Config.Provider.traverse_env/2`, which is private. Access.fetch/2 raises on a
  # value that is not accessible; Mix rescues that to `false`. Here a non-accessible
  # value simply is not `recorded`, so it reports as differing — which is true, and
  # avoids a rescue (`spec/10-decisions.md#no-rescue`).
  defp traverse(return, []), do: return
  defp traverse(:error, _path), do: :error

  defp traverse({:ok, value}, [key | keys]) do
    if is_map(value) or is_list(value),
      do: traverse(Access.fetch(value, key), keys),
      else: :error
  end

  @doc """
  The manifest's term, or why it could not be read.

  `{:ok, {elixir_and_otp, scm, lock}}`, `:absent` when there is no manifest — the
  `:error` branch of Mix's own check, and a different cause from a mismatch — or
  `:unreadable` when the file exists and does not hold the term Mix writes.
  """
  def read(build_path) do
    with {:ok, binary} <- File.read(path(build_path)),
         {:ok, term} <- decode(binary),
         {_vsn, vsn_pair, scm, lock} <- term do
      {:ok, {vsn_pair, scm, lock}}
    else
      {:error, _posix} -> :absent
      _other -> :unreadable
    end
  end

  @doc "Where Mix keeps it, which a reader needs in order to fetch it themselves."
  def path(build_path), do: Path.join([to_string(build_path), ".mix", "compile.elixir_scm"])

  # An external-term-format binary begins with 131. Checking that byte is what
  # keeps this free of `rescue`, which this project does not use: a file that is
  # not a term at all — a text file, a truncated-to-nothing write — is reported as
  # unreadable rather than raising.
  #
  # A binary that DOES begin with 131 and is corrupt still raises, and that is
  # deliberate. Mix wrote this file with `term_to_binary`, so a corrupt one means
  # a damaged object came out of the store, which is exactly the surprise worth
  # surfacing rather than swallowing. `:safe` keeps a hostile term from creating
  # atoms while we are at it.
  defp decode(<<131, _rest::binary>> = binary), do: {:ok, :erlang.binary_to_term(binary, [:safe])}
  defp decode(_not_a_term), do: :not_a_term

  @doc """
  Field-by-field verdict: `[{field, :same | {:differs, detail}}]`.

  Fields are in the order Mix compares them, so the first `:differs` is the one
  Mix would have acted on. For `lock` the detail carries the index of the first
  differing tuple element, or `:shape` when the two are not tuples of one size.
  """
  def compare({stored_vsn, stored_scm, stored_lock}, {vsn, scm, lock}) do
    [
      {:elixir_otp, same_or_differs(stored_vsn, vsn)},
      {:scm, same_or_differs(stored_scm, scm)},
      {:lock, lock_verdict(stored_lock, lock)}
    ]
  end

  defp same_or_differs(a, a), do: :same
  defp same_or_differs(a, b), do: {:differs, %{stored: a, expected: b}}

  defp lock_verdict(a, a), do: :same

  defp lock_verdict(a, b) when is_tuple(a) and is_tuple(b) and tuple_size(a) == tuple_size(b) do
    index = Enum.find(0..(tuple_size(a) - 1), fn i -> elem(a, i) != elem(b, i) end)
    {:differs, %{stored: a, expected: b, element: index}}
  end

  defp lock_verdict(a, b), do: {:differs, %{stored: a, expected: b, element: :shape}}

  @doc "Whether any field differs — what decides if there is anything to print."
  def differs?(verdicts), do: Enum.any?(verdicts, fn {_field, v} -> v != :same end)
end
