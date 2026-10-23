import json
import pathlib
import sqlite3
import sys


def _totals(row):
    return {
        "requestCount": row[0],
        "successCount": row[1],
        "failureCount": row[2],
        "inputTokens": row[3],
        "outputTokens": row[4],
        "totalTokens": row[5],
    }


def _query(database, start_ms, end_ms):
    uri = database.resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(uri, uri=True, timeout=0.25) as connection:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA busy_timeout=250")
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if version != 1:
            raise RuntimeError("schema")
        total = connection.execute(
            """
            SELECT count(*),
                   coalesce(sum(outcome = 'success'), 0),
                   coalesce(sum(outcome = 'failure'), 0),
                   coalesce(sum(input_tokens), 0),
                   coalesce(sum(output_tokens), 0),
                   coalesce(sum(total_tokens), 0)
            FROM usage_events
            WHERE occurred_utc_ms >= ? AND occurred_utc_ms < ?
            """,
            (start_ms, end_ms),
        ).fetchone()
        groups = [
            {
                "profileId": row[0],
                "providerId": row[1],
                "modelAlias": row[2],
                "totals": _totals(row[3:]),
            }
            for row in connection.execute(
                """
                SELECT profile_id, provider_id, model_alias,
                       count(*),
                       coalesce(sum(outcome = 'success'), 0),
                       coalesce(sum(outcome = 'failure'), 0),
                       coalesce(sum(input_tokens), 0),
                       coalesce(sum(output_tokens), 0),
                       coalesce(sum(total_tokens), 0)
                FROM usage_events
                WHERE occurred_utc_ms >= ? AND occurred_utc_ms < ?
                GROUP BY profile_id, provider_id, model_alias
                ORDER BY coalesce(sum(total_tokens), 0) DESC,
                         profile_id, provider_id, model_alias
                """,
                (start_ms, end_ms),
            )
        ]
        recent_errors = [
            {
                "occurredUtcMilliseconds": row[0],
                "profileId": row[1],
                "providerId": row[2],
                "modelAlias": row[3],
                "errorCode": row[4] or "upstream_failure",
            }
            for row in connection.execute(
                """
                SELECT occurred_utc_ms, profile_id, provider_id, model_alias, error_code
                FROM usage_events
                WHERE occurred_utc_ms >= ? AND occurred_utc_ms < ? AND outcome = 'failure'
                ORDER BY occurred_utc_ms DESC, id DESC
                LIMIT 20
                """,
                (start_ms, end_ms),
            )
        ]
    return {
        "schemaVersion": 1,
        "databasePresent": True,
        "windowStartUtcMilliseconds": start_ms,
        "windowEndUtcMilliseconds": end_ms,
        "totals": _totals(total),
        "groups": groups,
        "recentErrors": recent_errors,
    }


def main():
    if len(sys.argv) != 4:
        raise SystemExit(2)
    database = pathlib.Path(sys.argv[1])
    try:
        start_ms = int(sys.argv[2])
        end_ms = int(sys.argv[3])
        if start_ms < 0 or end_ms <= start_ms:
            raise ValueError()
        result = _query(database, start_ms, end_ms)
    except RuntimeError as exception:
        if str(exception) == "schema":
            print(json.dumps({"schemaVersion": 1, "errorCode": "aigw_usage_schema_unsupported"}))
            raise SystemExit(20)
        raise
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))


main()
