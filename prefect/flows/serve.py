"""Entry point of the prefect-flows container.

serve() registers every deployment below (with its schedule) against the
Prefect API, then polls for runs and executes them as subprocesses of this
process. There is no work pool, no worker and no deploy step: a new or changed
flow takes effect when this container restarts, and every `make up`
force-recreates it anyway.

If the API is not up yet, serve() exits and `restart: unless-stopped` brings
it back -- the retry is the restart.
"""

from __future__ import annotations

from datetime import timedelta

from prefect import serve
from prefect.schedules import Cron, Interval

from organize_inbox import organize_inbox
from pr_validation import pr_validation


def deployments() -> list:
    return [
        pr_validation.to_deployment(
            name="nightly",
            schedule=Cron("0 3 * * *", timezone="America/Toronto"),
        ),
        organize_inbox.to_deployment(
            name="every-15m",
            schedule=Interval(timedelta(minutes=15)),
        ),
    ]


if __name__ == "__main__":
    serve(*deployments())
