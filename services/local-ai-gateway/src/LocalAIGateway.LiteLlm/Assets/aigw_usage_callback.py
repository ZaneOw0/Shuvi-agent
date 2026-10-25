import asyncio
import json
import os
import re
import sqlite3
import threading
import time

from litellm.integrations.custom_logger import CustomLogger

_DAY_MS = 86_400_000
_RETENTION_MS = 365 * _DAY_MS
_ERROR_CODE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
_MAX_TOKEN_COUNT = 9_223_372_036_854_775_807


def _bounded_text(value, maximum):
    if not isinstance(value, str) or not value or len(value) > maximum:
        return None
    if any(ord(character) < 32 for character in value):
        return None
    return value


def _token_count(value):
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < 0 or value > _MAX_TOKEN_COUNT:
        return None
    return value


def _load_metadata():
    try:
        path = os.environ.get("AIGW_USAGE_METADATA")
        if not path:
            return None
        with open(path, "r", encoding="utf-8") as stream:
            value = json.load(stream)
        if value.get("version") != 1:
            return None
        profile_id = _bounded_text(value.get("profileId"), 128)
        models = value.get("models")
        if profile_id is None or not isinstance(models, dict):
            return None
        safe_models = {}
        for alias, provider_id in models.items():
            safe_alias = _bounded_text(alias, 128)
            safe_provider = _bounded_text(provider_id, 128)
            if safe_alias is None or safe_provider is None:
                return None
            safe_models[safe_alias] = safe_provider
        return profile_id, safe_models
    except Exception:
        return None


class LocalAIGatewayUsageLogger(CustomLogger):
    def __init__(self):
        super().__init__()
        self._database = os.environ.get("AIGW_USAGE_DATABASE")
        self._metadata = _load_metadata()
        self._last_prune_day = None
        self._write_lock = threading.Lock()

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        await self._record_fail_open(kwargs, "success")

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        await self._record_fail_open(kwargs, "failure")

    async def _record_fail_open(self, kwargs, outcome):
        try:
            await asyncio.to_thread(self._record, kwargs, outcome)
        except Exception:
            return

    def _record(self, kwargs, outcome):
        if not self._database or self._metadata is None or not isinstance(kwargs, dict):
            return
        payload = kwargs.get("standard_logging_object")
        if not isinstance(payload, dict):
            return

        profile_id, model_map = self._metadata
        model_alias = _bounded_text(payload.get("model_group"), 128)
        if model_alias is None or model_alias not in model_map:
            return
        provider_id = model_map[model_alias]

        raw_tokens = (
            payload.get("prompt_tokens"),
            payload.get("completion_tokens"),
            payload.get("total_tokens"),
        )
        if outcome == "failure" and all(value is None for value in raw_tokens):
            input_tokens = output_tokens = total_tokens = None
        else:
            input_tokens, output_tokens, total_tokens = map(_token_count, raw_tokens)
            if input_tokens is None or output_tokens is None or total_tokens is None:
                return
            if total_tokens < input_tokens or total_tokens < output_tokens:
                return

        occurred_utc_ms = int(time.time() * 1000)

        error_code = None
        if outcome == "failure":
            error_information = payload.get("error_information")
            candidate = error_information.get("error_code") if isinstance(error_information, dict) else None
            error_code = candidate if isinstance(candidate, str) and _ERROR_CODE.fullmatch(candidate) else "upstream_failure"

        with self._write_lock:
            self._write(
                occurred_utc_ms,
                profile_id,
                provider_id,
                model_alias,
                outcome,
                input_tokens,
                output_tokens,
                total_tokens,
                error_code,
            )

    def _write(self, occurred_utc_ms, profile_id, provider_id, model_alias, outcome,
               input_tokens, output_tokens, total_tokens, error_code):
        with sqlite3.connect(self._database, timeout=0.25) as connection:
            connection.execute("PRAGMA busy_timeout=250")
            mode = connection.execute("PRAGMA journal_mode=WAL").fetchone()
            if mode is None or str(mode[0]).lower() != "wal":
                raise RuntimeError("WAL mode unavailable")
            connection.execute("PRAGMA synchronous=NORMAL")
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, 1):
                return
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS usage_events (
                    id INTEGER PRIMARY KEY,
                    occurred_utc_ms INTEGER NOT NULL CHECK (occurred_utc_ms >= 0),
                    profile_id TEXT NOT NULL CHECK (length(profile_id) BETWEEN 1 AND 128),
                    provider_id TEXT NOT NULL CHECK (length(provider_id) BETWEEN 1 AND 128),
                    model_alias TEXT NOT NULL CHECK (length(model_alias) BETWEEN 1 AND 128),
                    outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure')),
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    total_tokens INTEGER,
                    error_code TEXT CHECK (error_code IS NULL OR length(error_code) BETWEEN 1 AND 64),
                    CHECK (
                        (input_tokens IS NULL AND output_tokens IS NULL AND total_tokens IS NULL) OR
                        (input_tokens >= 0 AND output_tokens >= 0 AND total_tokens >= input_tokens AND
                         total_tokens >= output_tokens)
                    ),
                    CHECK (outcome = 'failure' OR input_tokens IS NOT NULL)
                ) STRICT
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS ix_usage_events_occurred ON usage_events(occurred_utc_ms)"
            )
            if version == 0:
                connection.execute("PRAGMA user_version=1")
            connection.execute(
                """
                INSERT INTO usage_events (
                    occurred_utc_ms, profile_id, provider_id, model_alias, outcome,
                    input_tokens, output_tokens, total_tokens, error_code
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    occurred_utc_ms, profile_id, provider_id, model_alias, outcome,
                    input_tokens, output_tokens, total_tokens, error_code,
                ),
            )
            current_day = occurred_utc_ms // _DAY_MS
            if self._last_prune_day != current_day:
                connection.execute(
                    "DELETE FROM usage_events WHERE occurred_utc_ms < ?",
                    (occurred_utc_ms - _RETENTION_MS,),
                )
                self._last_prune_day = current_day


usage_logger = LocalAIGatewayUsageLogger()
