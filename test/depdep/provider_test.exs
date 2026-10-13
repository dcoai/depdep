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

  # `name/1` is `resolve/1` read backwards, and the pair is what puts a provider's
  # name into a report line and into a root's path — so the two have to agree about
  # every provider, not just the ones a caller happens to try (#201, for #160).
  #
  # The ROUND TRIP rather than `name(Provider.Mix) == "mix"`: a literal pair just
  # restates the module's own table, and would still pass if a provider were added
  # to one direction only, which is the way this breaks.
  @tag verifies: "spec/05-units-and-providers.md#contract"
  test "every provider name survives a round trip through resolve and back" do
    names = Provider.known() |> String.split(", ")

    assert names != [], "known/0 lists no providers, so this test would check nothing"
    assert Provider.default() -- names == [], "the default names a provider known/0 omits"

    for name <- names do
      assert {:ok, [module]} = Provider.resolve([name])
      assert Provider.name(module) == name
    end
  end
end
