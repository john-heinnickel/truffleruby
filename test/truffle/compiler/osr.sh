#!/usr/bin/env bash

source test/truffle/common.sh.inc

jt ruby --graal -J-Dgraal.TruffleCompilationExceptionsAreFatal test/truffle/compiler/osr/osr.rb
