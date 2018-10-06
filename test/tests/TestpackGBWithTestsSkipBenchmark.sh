#!/usr/bin/env bash

testTestPackGBWithTestsSkipBenchmark() {
  fixture "gb-with-tests"

  env "GO_TEST_SKIP_BENCHMARK" "nope"

  dotest
  assertCapturedSuccess
  assertCaptured "RUN   TestHello"
  assertCaptured "PASS: TestHello"
  assertCaptured "RUN   ExampleHello"
  assertCaptured "PASS: ExampleHello"
  assertNotCaptured "BenchmarkHello"
}

if [ "$0" = "$BASH_SOURCE" ]; then
    pushd $(dirname 0) >/dev/null
    popd >/dev/null

    source $(pwd)/test/utils
    source $(pwd)/test/shunit2
fi