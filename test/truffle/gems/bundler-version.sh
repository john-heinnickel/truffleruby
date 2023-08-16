#!/usr/bin/env bash

source test/truffle/common.sh.inc

jt gem-test-pack
gem_test_pack=$(jt gem-test-pack)

mkdir -p temp-gem-home

GEM_HOME=$PWD/temp-gem-home jt gem install --local "$gem_test_pack/gem-cache/bundler-1.17.3.gem"

output=$(GEM_HOME=$PWD/temp-gem-home jt ruby -Ctest/truffle/gems/bundler-version/one bundler-version.rb)

if [ "$output" = 'true' ]; then
  echo Success
else
  echo Unexpected bundler 1 output
  echo "$output"
  exit 1
fi

output=$(GEM_HOME=$PWD/temp-gem-home jt ruby -Ctest/truffle/gems/bundler-version/two bundler-version.rb)

if [ "$output" = 'true' ]; then
  echo Success
else
  echo Unexpected bundler 2 output
  echo "$output"
  exit 1
fi

rm -r temp-gem-home
