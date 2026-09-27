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
from prefect.client.schemas.objects import ConcurrencyLimitConfig
from prefect.schedules import Cron, Interval

from organize_inbox import organize_inbox
from pr_validation import pr_validation
from sort_mail import sort_mail


# One run of each deployment at a time: an organize-inbox run can outlast its
# 15-minute interval (20 notes against one Ollama), and a second run would
# race the first for the same notes.
ONE_AT_A_TIME = ConcurrencyLimitConfig(limit=1, collision_strategy="CANCEL_NEW")


def deployments() -> list:
    return [
        pr_validation.to_deployment(
            name="nightly",
            schedule=Cron("0 3 * * *", timezone="America/Toronto"),
            concurrency_limit=ONE_AT_A_TIME,
        ),
        organize_inbox.to_deployment(
            name="every-15m",
            schedule=Interval(timedelta(minutes=15)),
            concurrency_limit=ONE_AT_A_TIME,
        ),
        sort_mail.to_deployment(
            name="every-15m",
            schedule=Interval(timedelta(minutes=15)),
            concurrency_limit=ONE_AT_A_TIME,
            # Dry until the user has read what it would do: every push to main
            # deploys, and a registered deployment runs at once. Removed by a
            # separate commit once the dry-run log reads right.
            parameters={"dry_run": True},
        ),
    ]


if __name__ == "__main__":
    serve(*deployments())
