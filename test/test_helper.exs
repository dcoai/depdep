# `apt_integration` tests shell out to a real apt-get and reach a real Debian
# mirror. They are excluded by default so `mix test` stays hermetic and works on
# a machine with no apt at all; run them where both exist:
#
#     mix test --include apt_integration
#
# CI runs them in the `apt-round-trip` job of the `store` stage, which has apt
# and a MinIO service (#105). They ran nowhere at all before that.
ExUnit.start(exclude: [:apt_integration])

# `Surfex.ExUnitFormatter` records each test's result at its exact version, which
# is what `mix surfex.baseline` and `mix surfex.confirm --evidence` read (#129).
# Without it both refuse: surfex 0.5 validates an `implements` relation by what a
# test DID — red then green against the code — rather than by a human asserting it.
ExUnit.configure(formatters: [Surfex.ExUnitFormatter, ExUnit.CLIFormatter])
