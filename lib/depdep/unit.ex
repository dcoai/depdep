defmodule Depdep.Unit do
  @moduledoc """
  One thing that can be stored and restored: a compiled dependency, a package,
  a repository mirror.

  A unit is what a provider hands back from `c:Depdep.Provider.enumerate/1` and
  the only thing `Depdep.CLI` ever handles. Everything the provider needs to act
  on it later lives in `:context`, which nothing outside that provider reads —
  that is what lets the transfer loop stay ignorant of what it is moving.

  `:group` and `:name` are separate because `--plan` prints them as separate
  columns and a provider with no grouping (packages are not per-project) leaves
  `:group` nil rather than inventing one.
  """

  @type resolution :: {:key, String.t()} | {:skip, String.t()}

  @type t :: %__MODULE__{
          group: String.t() | nil,
          name: String.t(),
          detail: String.t(),
          resolution: resolution(),
          object: String.t() | nil,
          context: term()
        }

  @enforce_keys [:name, :resolution]
  defstruct [:group, :name, :detail, :resolution, :object, :context]

  @doc "How this unit is named in a message: `platform/crm/ash`, or just `ash`."
  def label(%__MODULE__{group: nil, name: name}), do: name
  def label(%__MODULE__{group: group, name: name}), do: "#{group}/#{name}"
end
