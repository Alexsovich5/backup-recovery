#!/usr/bin/env bats
# Checks the test runner itself.

@test "bats is 0.3.1" {
  run bats --version
  [ "$status" -eq 0 ]
  [ "$output" = "Bats 0.3.1" ]
}
