"""Rollout parser reference from main c4db71c1, before phase 1.

Parsing methods and cursors below are copied unchanged. Discovery is replaced by the
fixture's known path; reading() supplies the former Service's independent failure boundaries.
This reference only reads the scratch rollout supplied by its caller.
"""
from __future__ import annotations

import json
import logging
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from aitermd.jsonl import JsonlCursor, records_newest_first
from aitermd.models import State
from aitermd.text import iso_seconds, nonempty_string
from aitermd.usage import clamped_percent, finite_number

_TOKEN_COUNT = b'"token_count"'
_SESSION_META = b'"session_meta"'
Stamp = tuple[Path, int, int]


@dataclass(slots=True)
class _MetaCursor(JsonlCursor):
    """How far one rollout has been read for its `session_meta` records: the byte offset, the inode it
    was read from, the start of a line Codex was still writing, and the version found so far."""
    version: str | None = None


@dataclass(slots=True)
class _TurnCursor(JsonlCursor):
    latest: tuple[State, float] | None = None


class MainCodexReference:
    def __init__(self, path: Path):
        self.path = path
        self._versions: dict[Path, _MetaCursor] = {}
        self._turns: dict[Path, _TurnCursor] = {}
        self._context: dict[str, tuple[Stamp, int | None]] = {}

    def _path_for(self, session_id: str) -> Path:
        return self.path

    def reading(self, thread_id: str):
        fields = []
        for method in (self.context_percent, self.cli_version, self.turn_state):
            try:
                fields.append(method(thread_id))
            except Exception:  # the former Service isolated each field and logged its failure
                logging.getLogger("aitermd.service").exception("reference Codex field read failed")
                fields.append(None)
        return tuple(fields)

    def context_percent(self, session_id: str) -> int | None:
        path = self._path_for(session_id)
        if path is None:
            return None
        try:
            st = path.stat()
        except OSError:
            return None
        stamp = (path, st.st_mtime_ns, st.st_size)
        cached = self._context.get(session_id)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        try:
            percent = self._read_context(path)
        except OSError:
            return None
        self._context[session_id] = (stamp, percent)
        return percent


    def cli_version(self, thread_id: str) -> str | None:
        """The Codex version that runs the thread: `cli_version` in the newest `session_meta` record
        its rollout holds for it -- the record a session starts with; another one later in the file,
        from a resume, wins. None before the rollout names one. A rollout only grows, so it is read on
        from where the last read stopped, and one rewritten is read again from its start."""
        path = self._path_for(thread_id)
        if path is None:
            return None
        try:
            st = path.stat()
        except OSError:
            return None
        cursor = self._versions.get(path)
        if cursor is None or cursor.rewritten(st.st_ino, st.st_size):
            cursor = self._versions[path] = _MetaCursor(st.st_ino)
        try:
            lines = cursor.read_lines(path, st.st_size)
        except OSError:
            return cursor.version
        for line in lines:
            if _SESSION_META in line and (version := _meta_version(line, thread_id)) is not None:
                cursor.version = version
        return cursor.version


    def turn_state(self, thread_id: str) -> tuple[State, float] | None:
        """The latest explicit turn boundary, with its own precise wall-clock stamp. Text alone
        cannot end a turn. Read incrementally, and discard remembered completion on interruption."""
        path = self._path_for(thread_id)
        if path is None:
            return None
        try:
            st = path.stat()
            cursor = self._turns.get(path)
            if cursor is None or cursor.rewritten(st.st_ino, st.st_size):
                cursor = self._turns[path] = _TurnCursor(st.st_ino)
            for line in cursor.read_lines(path, st.st_size):
                if not any(kind in line for kind in (b'"task_started"', b'"task_complete"', b'"turn_aborted"')):
                    continue
                try:
                    record = json.loads(line)
                except (UnicodeDecodeError, ValueError):
                    continue
                payload = record.get("payload") if isinstance(record, dict) and record.get("type") == "event_msg" else None
                if not isinstance(payload, dict):
                    continue
                kind = payload.get("type")
                if kind == "turn_aborted":
                    cursor.latest = None
                elif kind in ("task_started", "task_complete"):
                    stamp = iso_seconds(record.get("timestamp"))
                    cursor.latest = ("working" if kind == "task_started" else "done", stamp) if stamp is not None else None
            return cursor.latest
        except OSError:
            return None


    def _read_context(self, path: Path) -> int | None:
        for _, payload in self._token_counts(path):
            info = payload.get("info")
            last = info.get("last_token_usage") if isinstance(info, dict) else None
            total = finite_number(last.get("total_tokens")) if isinstance(last, dict) else None
            window = finite_number(info.get("model_context_window")) if isinstance(info, dict) else None
            if total is None or window is None or window <= 0:
                continue
            if (percent := clamped_percent(total / window * 100)) is not None:
                return percent
        return None


    @classmethod
    def _token_counts(cls, path: Path) -> Iterator[tuple[dict[str, Any], dict[str, Any]]]:
        """Every `token_count` event of a rollout, newest first, with the record that carries it."""
        # Most of a rollout is messages and tool output: parsing them to find that they are not
        # token counts made a rollout with none cost tens of milliseconds a megabyte.
        for record in records_newest_first(path, None, containing=_TOKEN_COUNT):
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            payload = record.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "token_count":
                yield record, payload



def _meta_version(line: bytes, thread_id: str) -> str | None:
    """The `cli_version` of a `session_meta` record for `thread_id`; None for any other line."""
    try:
        record = json.loads(line)
    except (UnicodeDecodeError, ValueError):
        return None
    payload = record.get("payload") if isinstance(record, dict) and record.get("type") == "session_meta" else None
    if not isinstance(payload, dict) or payload.get("id") != thread_id:
        return None
    return nonempty_string(payload.get("cli_version"))

