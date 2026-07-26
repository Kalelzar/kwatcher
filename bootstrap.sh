#!/usr/bin/env sh
# Initialize submodules for building the kwatcher umbrella.
#
# Do NOT use `git submodule update --init --recursive` here: fully recursive
# init materializes every package's nested vendor tree (~800 build.zig.zon
# manifests) and overwhelms zig's dependency-graph walk. Inside the umbrella
# the packages resolve each other as siblings, so nested vendor copies are
# unnecessary — only the build-time imports and vendored C dependencies below
# must exist on disk.
#
# Shallow fetches assume every pin sits on a remote branch tip (currently
# true); run `git fetch --unshallow` inside a submodule if you need history.
set -e
git submodule update --init --jobs 8 --depth 1
git -C packages/core       submodule update --init --depth 1 vendor/zettel
git -C packages/protocol   submodule update --init --depth 1 vendor/zettel
git -C packages/kwev       submodule update --init --depth 1 vendor/zstd
git -C packages/orm-sqlite submodule update --init --depth 1 vendor/sqlite3
git -C packages/amqp       submodule update --init --depth 1 vendor/zamqp
git -C packages/amqp/vendor/zamqp submodule update --init --depth 1 vendor/rabbitmq-c
