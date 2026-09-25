# `apt_integration` tests shell out to a real apt-get and reach a real Debian
# mirror. They are excluded by default so `mix test` stays hermetic and works on
# a machine with no apt at all; run them where both exist:
#
#     mix test --include apt_integration
#
# CI runs them in the `apt-round-trip` job of the `store` stage, which has apt
# and a MinIO service (#105). They ran nowhere at all before that.
ExUnit.start(exclude: [:apt_integration])
