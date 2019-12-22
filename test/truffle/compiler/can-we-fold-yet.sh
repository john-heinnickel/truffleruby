#!/usr/bin/env bash

source test/truffle/common.sh.inc

jt ruby --engine.IterativePartialEscape=true doc/samples/can-we-fold-yet.rb < test/truffle/compiler/can-we-fold-yet/input.txt > actual.txt

if ! cmp test/truffle/compiler/can-we-fold-yet/expected.txt actual.txt
then
  echo Output not as expected
  echo Expected:
  cat test/truffle/compiler/can-we-fold-yet/expected.txt
  if [ -e actual.txt ]
  then
    echo Actual:
    cat actual.txt
    echo Diff:
    diff test/truffle/compiler/can-we-fold-yet/expected.txt actual.txt
    rm -f actual.txt
  fi
  exit 1
fi

rm -f actual.txt
