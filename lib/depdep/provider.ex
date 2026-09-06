defmodule Depdep.Provider do
  @moduledoc """
  What a kind of artifact has to answer for the depot to carry it.

  The store, the signing, the concurrency, the fail-safe reporting and the
  bucket accounting are all indifferent to what is being moved. A provider
  supplies the four things that are not:

    * what is wanted, and what each of those keys to (`c:enumerate/1`)
    * whether one is already satisfied on disk (`c:present?/1`)
    * how to put a fetched object where the tool that needs it will look
      (`c:restore/2`)
    * how to turn what is on disk into an object (`c:collect/2`)

  **Iteration belongs to the provider, not to the caller.** `Depdep.Provider.Mix`
  walks poncho members, each with their own `deps/` and `_build/`; a package
  provider has no such notion. So `c:enumerate/1` yields a flat list of units
  and keeps its own traversal to itself.

  **A key is a provider's own business.** `Depdep.Provider.Mix` uses a recursive
  Merkle hash because an Elixir dependency's compiled output is a function of
  its dependencies' compiled output. Nothing else here is expected to — a
  distribution package is built once for everyone and is already identified
  exactly by its filename, so a flat key is the right key for it, not a
  compromise. The seam takes no position.
  """

  alias Depdep.Unit

  @typedoc """
  Command-line options, plus `:root`, `:env` and `:direction`.

  `:direction` is `:pull` or `:push`, because what a provider wants moved can
  differ between them — `Depdep.Provider.Apt` asks apt what it WILL fetch on a
  pull and asks the archives directory what WAS fetched on a push. `--plan`
  passes `:pull`, since a plan shows what a pull would do.

  **A provider cannot read the store.** `c:enumerate/1` names what it wants from
  what it can see locally; the caller does every transfer. An earlier version
  passed in a fetch function for a provider that could not name its units
  without reading an object first — and no such provider turned out to exist.
  If one ever does, add it back with the implementation that needs it and a test
  that exercises it.
  """
  @type opts :: keyword()

  @doc """
  What this provider wants moved, plus anything it could not enumerate.

  Warnings are returned rather than printed so IO stays in `Depdep.CLI`, and
  they are warnings rather than errors on purpose: one unreadable member of a
  poncho must not stop the other ten being restored.
  """
  @callback enumerate(opts()) :: {:ok, [Unit.t()], [String.t()]}

  @doc "Is this unit already satisfied on disk? A half-present unit is absent."
  @callback present?(Unit.t()) :: boolean()

  @doc "Put a fetched object, at `tmp`, where the tool that needs it will look."
  @callback restore(Unit.t(), Path.t()) :: :ok | {:error, String.t()}

  @doc "Write what is on disk for this unit into `tmp`, ready to be stored."
  @callback collect(Unit.t(), Path.t()) :: :ok | {:error, String.t()}

  @providers %{
    "mix" => Depdep.Provider.Mix,
    "apt" => Depdep.Provider.Apt,
    "git" => Depdep.Provider.Git
  }

  @doc "The provider used when none is named — today's behaviour, unchanged."
  def default, do: ["mix"]

  @doc "Names to modules, or `{:error, reason}` naming the one that is not known."
  def resolve([]), do: resolve(default())

  def resolve(names) do
    case Enum.reject(names, &Map.has_key?(@providers, &1)) do
      [] -> {:ok, Enum.map(names, &Map.fetch!(@providers, &1))}
      [unknown | _] -> {:error, "no such provider #{inspect(unknown)}, known: #{known()}"}
    end
  end

  @doc "The provider names this build understands."
  def known, do: @providers |> Map.keys() |> Enum.sort() |> Enum.join(", ")
end
