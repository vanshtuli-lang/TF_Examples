"""Smoke test: proves the scheduler, executor and Execution API work end to end."""

from datetime import datetime

from airflow.sdk import dag, task


@dag(schedule=None, start_date=datetime(2026, 1, 1), catchup=False, tags=["smoke-test"])
def smoke_test():
    @task
    def versions() -> str:
        import platform

        import airflow

        return f"Airflow {airflow.__version__} | Python {platform.python_version()}"

    @task
    def show(msg: str) -> None:
        print(msg)

    show(versions())


smoke_test()
