import pathlib
import sqlite3
import sys


database = pathlib.Path(sys.argv[1])
if not database.exists():
    raise SystemExit(1)

with sqlite3.connect(database) as connection:
    rows = connection.execute(
        """
        SELECT profile_id, provider_id, model_alias, outcome,
               input_tokens, output_tokens, total_tokens, error_code
        FROM usage_events ORDER BY id
        """
    ).fetchall()

expected = ("profile", "provider", "public-model", "success", 13, 5, 18, None)
if len(rows) != 20 or rows[-1] != expected:
    raise SystemExit(1)

for candidate in database.parent.glob(database.name + "*"):
    if b"proxy-response-canary-m5a" in candidate.read_bytes():
        raise SystemExit(2)

print("M5a real LiteLLM usage event acceptance passed")
