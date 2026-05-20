from __future__ import annotations

import time

from django.core.management.base import BaseCommand

from portal import services


class Command(BaseCommand):
    help = "Run the portal job worker."

    def add_arguments(self, parser):
        parser.add_argument(
            "--once",
            action="store_true",
            help="Process at most one job and exit.",
        )
        parser.add_argument(
            "--idle-sleep",
            type=float,
            default=2.0,
            help="Seconds to sleep when no queued job is available.",
        )

    def handle(self, *args, **options):
        once = options["once"]
        idle_sleep = options["idle_sleep"]

        recovered_count = services.mark_stale_running_jobs_failed()
        if recovered_count:
            self.stdout.write(f"Recovered {recovered_count} stale running job(s) as failed.")

        while True:
            job = services.claim_and_process_next_job()
            if job is None:
                if once:
                    self.stdout.write("No queued jobs found.")
                    return
                time.sleep(idle_sleep)
                continue

            self.stdout.write(
                f"Processed job {job.submission_id} with status {job.get_status_display()}."
            )
            if once:
                return
