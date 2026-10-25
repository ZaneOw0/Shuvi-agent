import asyncio
import importlib.util
import pathlib
import sqlite3
import sys
import time


CALLBACK_PATH = pathlib.Path(sys.argv[1])
DATABASE_PATH = pathlib.Path(sys.argv[2])
DAY_SECONDS = 86_400
CANARIES = (
    "prompt-canary-m5a",
    "response-canary-m5a",
    "tool-argument-canary-m5a",
    "authorization-canary-m5a",
    "amount-canary-m5a",
)


def load_callback():
    spec = importlib.util.spec_from_file_location("aigw_usage_callback", CALLBACK_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load callback module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.usage_logger


def payload(when, input_tokens, output_tokens, total_tokens, error_code=None):
    value = {
        "model_group": "public-model",
        "prompt_tokens": input_tokens,
        "completion_tokens": output_tokens,
        "total_tokens": total_tokens,
        "endTime": when,
        "messages": CANARIES[0],
        "response": CANARIES[1],
        "mcp_tool_call_metadata": {"arguments": CANARIES[2]},
        "metadata": {"requester_custom_headers": {"authorization": CANARIES[3]}},
        "response_cost": CANARIES[4],
    }
    if error_code is not None:
        value["error_information"] = {"error_code": error_code}
    return {"standard_logging_object": value}


async def run():
    logger = load_callback()
    now = time.time()

    logger._record(payload(now, 1, 2, 3), "success")
    with sqlite3.connect(DATABASE_PATH) as connection:
        connection.execute("DELETE FROM usage_events")
        connection.execute(
            """
            INSERT INTO usage_events (
                occurred_utc_ms, profile_id, provider_id, model_alias, outcome,
                input_tokens, output_tokens, total_tokens, error_code
            ) VALUES (?, 'profile', 'provider', 'public-model', 'success', 1, 2, 3, NULL)
            """,
            (int((now - (366 * DAY_SECONDS)) * 1000),),
        )
    logger._last_prune_day = None
    await logger.async_log_success_event(payload(now, 11, 7, 18), None, None, None)
    await logger.async_log_failure_event(
        payload(now, 0, 0, 0, "bad code with spaces"), None, None, None
    )
    missing_usage_failure = payload(now, 0, 0, 0, "429")
    for token_field in ("prompt_tokens", "completion_tokens", "total_tokens"):
        del missing_usage_failure["standard_logging_object"][token_field]
    await logger.async_log_failure_event(missing_usage_failure, None, None, None)
    await logger.async_log_success_event({}, None, None, None)

    with sqlite3.connect(DATABASE_PATH) as connection:
        mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
        if str(mode).lower() != "wal":
            raise AssertionError(f"Expected WAL, got {mode}")
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if version != 1:
            raise AssertionError(f"Expected schema 1, got {version}")
        columns = [row[1] for row in connection.execute("PRAGMA table_info(usage_events)")]
        expected_columns = [
            "id",
            "occurred_utc_ms",
            "profile_id",
            "provider_id",
            "model_alias",
            "outcome",
            "input_tokens",
            "output_tokens",
            "total_tokens",
            "error_code",
        ]
        if columns != expected_columns:
            raise AssertionError(f"Unexpected columns: {columns}")
        rows = connection.execute(
            """
            SELECT profile_id, provider_id, model_alias, outcome,
                   input_tokens, output_tokens, total_tokens, error_code
            FROM usage_events ORDER BY id
            """
        ).fetchall()
        expected_rows = [
            ("profile", "provider", "public-model", "success", 11, 7, 18, None),
            ("profile", "provider", "public-model", "failure", 0, 0, 0, "upstream_failure"),
            ("profile", "provider", "public-model", "failure", None, None, None, "429"),
        ]
        if rows != expected_rows:
            raise AssertionError(f"Unexpected rows: {rows}")

    await asyncio.gather(
        *(logger.async_log_success_event(payload(now, 1, 1, 2), None, None, None) for _ in range(16))
    )
    with sqlite3.connect(DATABASE_PATH) as connection:
        count = connection.execute("SELECT count(*) FROM usage_events").fetchone()[0]
        if count != 19:
            raise AssertionError(f"Concurrent callback writes were lost: {count}")
        connection.execute("PRAGMA user_version=2")

    await logger.async_log_success_event(payload(now, 3, 4, 7), None, None, None)
    with sqlite3.connect(DATABASE_PATH) as connection:
        count = connection.execute("SELECT count(*) FROM usage_events").fetchone()[0]
        if count != 19:
            raise AssertionError("Future schema was modified")
        connection.execute("PRAGMA user_version=1")
        connection.execute("BEGIN IMMEDIATE")
        await logger.async_log_success_event(payload(now, 5, 6, 11), None, None, None)
        connection.rollback()

    with sqlite3.connect(DATABASE_PATH) as connection:
        count = connection.execute("SELECT count(*) FROM usage_events").fetchone()[0]
        if count != 19:
            raise AssertionError("Locked database changed or fail-open did not return")

    for candidate in DATABASE_PATH.parent.glob(DATABASE_PATH.name + "*"):
        data = candidate.read_bytes()
        for canary in CANARIES:
            if canary.encode("utf-8") in data:
                raise AssertionError(f"Sensitive canary persisted in {candidate.name}")

    print("M5a callback acceptance passed: WAL, schema, retention, fail-open, privacy")


asyncio.run(run())
