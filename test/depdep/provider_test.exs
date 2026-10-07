defmodule Depdep.ProviderTest do
  use ExUnit.Case, async: true

  alias Depdep.Provider

  # Naming no provider must keep meaning what it meant before the seam existed,
  # or every consumer's committed bootstrap script quietly changes behaviour.
  test "no provider named means the mix provider" do
    assert Provider.resolve([]) == {:ok, [Provider.Mix]}
    assert Provider.default() == ["mix"]
  end

  test "providers resolve in the order they were given" do
    assert Provider.resolve(["mix", "mix"]) == {:ok, [Provider.Mix, Provider.Mix]}
  end

  test "providers are addressed by name" do
    assert Provider.resolve(["apt"]) == {:ok, [Provider.Apt]}
    assert Provider.resolve(["mix", "apt"]) == {:ok, [Provider.Mix, Provider.Apt]}
  end

  # An unknown provider is a typo in a bootstrap script. Saying which name was
  # not understood, and which are, is the difference between a one-second fix
  # and a confused pipeline.
  @tag verifies: "spec/05-units-and-providers.md#contract"
  test "an unknown provider names itself and the known ones" do
    assert {:error, reason} = Provider.resolve(["yum"])
    assert reason =~ ~s("yum")
    assert reason =~ "mix"
    assert reason =~ "apt"
  end
end
