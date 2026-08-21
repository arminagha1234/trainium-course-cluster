#!/usr/bin/env python3
"""
run_tests.py — gradescope-utils test runner for the PCS autograder.

Invoked last by ./run_autograder (after the harness result.json has been pulled
back from the cluster to /autograder/source/result.json). Discovers the tests
under ./tests, runs them, and writes Gradescope's results.json.

This is deliberately the same shape as the UC Berkeley lab6 run_tests.py; the
interesting, PCS-specific work happens in run_autograder (submit to the shared
cluster) and in tests/ (read the harness result.json). See README.md.
"""

import unittest

from gradescope_utils.autograder_utils.json_test_runner import JSONTestRunner


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.discover("tests")
    with open("/autograder/results/results.json", "w") as f:
        JSONTestRunner(visibility="visible", stream=f).run(suite)
