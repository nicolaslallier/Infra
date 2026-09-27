"""Plain-assert check that serve.py's deployments never overlap.

Run from the repo root:
  uv run --no-project --python 3.12 --with prefect==3.8.7 \
    python prefect/flows/test_serve.py
"""

from __future__ import annotations

import serve


def test_one_run_at_a_time():
    for deployment in serve.deployments():
        assert deployment.concurrency_limit == 1, deployment.name
        strategy = deployment.concurrency_options.collision_strategy
        assert strategy.value == "CANCEL_NEW", deployment.name


if __name__ == "__main__":
    test_one_run_at_a_time()
    print("ok test_one_run_at_a_time")
