"""Shared pytest / Hypothesis configuration for the property test suites.

This file defines two named Hypothesis profiles and selects one based on the
`HYPOTHESIS_PROFILE` environment variable (default: "default"):

  * default — used in CI and local runs. `max_examples=100`, matches the
    minimum required by Requirement 13.3 of the GROMACS spec and the
    LAMMPS spec's equivalent.
  * dev     — fast feedback while iterating. `max_examples=20`.
  * ci      — exhaustive; bumps `max_examples=500` for the nightly job.

Per-test `@settings(max_examples=...)` decorators in the individual test
files still override the profile for cases that need higher coverage
(e.g. the LAMMPS log-parser property at 300 examples).

Both `tests/test_lammps_properties.py` and `tests/test_gromacs_properties.py`
share this configuration so a single `pytest tests/` invocation runs both
suites with the same generation budget.
"""

from __future__ import annotations

import os

from hypothesis import HealthCheck, settings


# Default profile — at least 100 examples per property, matches the
# minimum required by the spec acceptance criteria.
settings.register_profile(
    "default",
    max_examples=100,
    deadline=None,  # property tests do non-trivial work; per-example timing
                    # is irrelevant to correctness
    suppress_health_check=[HealthCheck.too_slow],
)

# Fast iteration profile for local development.
settings.register_profile(
    "dev",
    max_examples=20,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)

# Exhaustive profile for nightly / pre-release validation.
settings.register_profile(
    "ci",
    max_examples=500,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)

settings.load_profile(os.environ.get("HYPOTHESIS_PROFILE", "default"))
