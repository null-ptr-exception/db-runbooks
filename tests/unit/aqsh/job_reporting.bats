#!/usr/bin/env bats

@test "job_report YAML compiles without changing unrelated task contracts" {
  run python3 "${BATS_TEST_DIRNAME}/test_job_reporting.py" ConfigTests
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output"; fi
  [ "$status" -eq 0 ]
}

@test "generic reporting preserves operation results, cleanup and timeout bounds" {
  run python3 "${BATS_TEST_DIRNAME}/test_job_reporting.py" RunnerTests DestinationTests ExternalTaskTests IntegrationTests
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output"; fi
  [ "$status" -eq 0 ]
}
