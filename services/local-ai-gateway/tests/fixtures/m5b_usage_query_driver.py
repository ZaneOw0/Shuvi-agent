import hashlib
import json
import pathlib
import sqlite3
import subprocess
import sys


QUERY_SCRIPT = pathlib.Path(sys.argv[1])
DATABASE = pathlib.Path(sys.argv[2])
START_MS = 2_000
END_MS = 4_000


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_query(start_ms=START_MS, end_ms=END_MS):
    return subprocess.run(
        [
            sys.executable,
            "-B",
            "-I",
            str(QUERY_SCRIPT),
            str(DATABASE),
            str(start_ms),
            str(end_ms),
        ],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


DATABASE.parent.mkdir(parents=True)
with sqlite3.connect(DATABASE) as connection:
    mode = connection.execute("PRAGMA journal_mode=WAL").fetchone()[0]
    if str(mode).lower() != "wal":
        raise AssertionError("WAL unavailable")
    connection.execute(
        """
        CREATE TABLE usage_events (
            id INTEGER PRIMARY KEY,
            occurred_utc_ms INTEGER NOT NULL,
            profile_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            model_alias TEXT NOT NULL,
            outcome TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            total_tokens INTEGER,
            error_code TEXT
        ) STRICT
        """
    )
    connection.execute("PRAGMA user_version=1")
    connection.executemany(
        """
        INSERT INTO usage_events (
            occurred_utc_ms, profile_id, provider_id, model_alias, outcome,
            input_tokens, output_tokens, total_tokens, error_code
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (1_000, "old", "old", "old", "success", 99, 99, 198, None),
            (2_500, "profile", "provider", "public-model", "success", 13, 5, 18, None),
            (3_000, "profile", "provider", "public-model", "failure", None, None, None, "429"),
        ],
    )
    connection.commit()
    database_hash = digest(DATABASE)
    wal_path = pathlib.Path(str(DATABASE) + "-wal")
    wal_hash = digest(wal_path)

    result = run_query()
    if result.returncode != 0:
        raise AssertionError(f"query failed: {result.returncode}: {result.stderr}")
    payload = json.loads(result.stdout)
    expected_totals = {
        "requestCount": 2,
        "successCount": 1,
        "failureCount": 1,
        "inputTokens": 13,
        "outputTokens": 5,
        "totalTokens": 18,
    }
    if payload["totals"] != expected_totals:
        raise AssertionError(f"unexpected totals: {payload['totals']}")
    if len(payload["groups"]) != 1 or payload["groups"][0]["totals"] != expected_totals:
        raise AssertionError(f"unexpected groups: {payload['groups']}")
    if len(payload["recentErrors"]) != 1 or payload["recentErrors"][0]["errorCode"] != "429":
        raise AssertionError(f"unexpected recent errors: {payload['recentErrors']}")
    if digest(DATABASE) != database_hash or digest(wal_path) != wal_hash:
        raise AssertionError("read-only query changed database or WAL bytes")
    count = connection.execute("SELECT count(*) FROM usage_events").fetchone()[0]
    if count != 3:
        raise AssertionError("read-only query changed stored rows")

    connection.execute("PRAGMA user_version=2")
    connection.commit()
    future = run_query()
    if future.returncode != 20:
        raise AssertionError(f"future schema was not rejected: {future.returncode}")
    if json.loads(future.stdout).get("errorCode") != "aigw_usage_schema_unsupported":
        raise AssertionError("future schema did not return the stable error code")
    connection.execute("PRAGMA user_version=1")
    connection.commit()

if list(DATABASE.parent.rglob("__pycache__")) or list(DATABASE.parent.rglob("*.pyc")):
    raise AssertionError("query created Python cache files")

print("M5b usage query acceptance passed: read-only WAL aggregation and future-schema rejection")
