#!/usr/bin/env bash

source test/truffle/common.sh.inc

ruby_version=$(jt ruby -v)

if [[ ! $ruby_version =~ "Oracle GraalVM Native" ]]; then
  echo Oracle GraalVM Native not detected, no tests to run.
  exit 0
fi

# Store the image
jt ruby --experimental-options --engine.TraceCache --engine.CacheCompile=executed --engine.CacheStore=core.image test/truffle/compiler/engine_caching/engine_caching.rb

ls -lh core.image

# Load the image
set +x
load_output=$(jt ruby --experimental-options --engine.TraceCache --engine.CacheLoad=core.image test/truffle/compiler/engine_caching/engine_caching.rb 2>&1)
echo "$load_output"

if [[ ! $load_output =~ "Engine from image successfully patched with new options" ]]; then
  echo Engine caching success trace log not detected.
  exit 1
fi
