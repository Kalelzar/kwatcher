#!/usr/bin/env sh
# Initialize submodules for building the kwatcher umbrella.
#
# Do NOT use `git submodule update --init --recursive` here: fully recursive
# init materializes every package's nested vendor tree (~800 build.zig.zon
# manifests) and overwhelms zig's dependency-graph walk. Inside the umbrella
# the packages resolve each other as siblings, so nested vendor copies are
# unnecessary — only the build-time imports and vendored C dependencies below
# must exist on disk.
set -e
git submodule update --init
git -C packages/core       submodule update --init vendor/zettel
git -C packages/protocol   submodule update --init vendor/zettel
git -C packages/kwev       submodule update --init vendor/zstd
git -C packages/orm-sqlite submodule update --init vendor/sqlite3
git -C packages/amqp       submodule update --init vendor/zamqp
git -C packages/amqp/vendor/zamqp submodule update --init vendor/rabbitmq-c
