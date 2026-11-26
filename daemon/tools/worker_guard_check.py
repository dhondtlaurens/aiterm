"""Drive a real agent CLI through an AiTerm worker launcher: Codex with scripted local Responses, or
Antigravity (`--cli agy`) with a real model asked to run the command.

Codex uses only a temporary CODEX_HOME/config and synthetic git repositories: no account or model.
Antigravity has no local model to script, so it runs signed in, on its smallest model, with
--dangerously-skip-permissions as a worker does: one short turn of quota. Either way the caller
writes launcher/agent files through WorkerGuardLaunch, so this checks the actual PATH shims rather
than a second implementation of their environment, and judges the push by the repository, not by
what the model says.
"""
import argparse
import json
import os
import pwd
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--agent", type=Path, required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--cli", choices=["codex", "agy"], default="codex")
    args = parser.parse_args()
    if args.cli == "agy":
        check_agy(args)
        return
    requests: list[dict[str, Any]] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *unused: Any) -> None:
            pass

        def do_POST(self) -> None:
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(payload)
            if len(requests) == 1:
                diagnostic = "command -v git\n" + args.command
                item: dict[str, Any] = {"type": "function_call", "name": "exec_command", "call_id": "guard-call", "id": "fc-guard",
                        "arguments": json.dumps({"cmd": diagnostic})}
            else:
                item = {"type": "message", "role": "assistant", "id": "msg-guard",
                        "content": [{"type": "output_text", "text": "guard check complete"}]}
            response_id = "response-" + str(len(requests))
            events: list[dict[str, Any]] = [{"type": "response.created", "response": {"id": response_id}},
                      {"type": "response.output_item.done", "output_index": 0, "item": item},
                      {"type": "response.completed", "response": {"id": response_id, "status": "completed", "output": [item]}}]
            data = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    with tempfile.TemporaryDirectory(prefix="aiterm-codex-worker-guard-") as temporary:
        home = Path(temporary)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        (home / "config.toml").write_text(
            'model = "guard-model"\nmodel_provider = "guard"\n'
            '[model_providers.guard]\nname = "Local guard proof"\n'
            f'base_url = "http://127.0.0.1:{server.server_port}/v1"\n'
            'wire_api = "responses"\nrequires_openai_auth = false\nsupports_websockets = false\n')
        codex = shutil.which("codex")
        if not codex:
            raise RuntimeError("Codex is not installed")
        words = ["codex", "--no-daemon", "exec", "--ephemeral", "--skip-git-repo-check",
                 "--dangerously-bypass-approvals-and-sandbox", "--json", "-C", args.cwd, "Run the scripted command once."]
        args.agent.write_text("#!/bin/sh\nexec " + shlex.join(words) + "\n")
        args.agent.chmod(0o700)
        env = {key: value for key, value in os.environ.items() if not key.startswith(("CODEX_", "OPENAI_", "ITERM_"))}
        env["CODEX_HOME"] = str(home)
        try:
            result = subprocess.run(["/bin/sh", "-c", args.launcher], env=env, cwd=args.cwd,
                                    capture_output=True, text=True, timeout=60)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        print(json.dumps({"exit": result.returncode, "requests": len(requests),
                          "feedback": [item.get("output") for request in requests for item in request.get("input", [])
                                       if item.get("type") == "function_call_output"]}))
        if result.returncode:
            print(result.stderr[-2000:])
        assert result.returncode == 0 and len(requests) == 2


def check_agy(args: argparse.Namespace) -> None:
    """One headless Antigravity turn, launched as a worker is, told to run the command once."""
    if not shutil.which("agy"):
        raise RuntimeError("Antigravity CLI is not installed")
    settings = json.dumps({"trustedWorkspaces": [args.cwd]})
    words = ["agy", "-p", f"Run exactly this shell command once, then stop and report its output: {args.command}",
             "--dangerously-skip-permissions", "--model", "gemini-3.8-flash-low", "--output-format", "json",
             "--settings", settings]
    # agy keeps its sign-in under the account's home, which a hermetic test environment replaces: it
    # alone gets the real one back. The git it runs keeps the guard's config, carried in GIT_CONFIG_*.
    home = pwd.getpwuid(os.getuid()).pw_dir
    args.agent.write_text("#!/bin/sh\nexec env HOME=" + shlex.quote(home) + " " + shlex.join(words) + "\n")
    args.agent.chmod(0o700)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("ITERM_",))}
    result = subprocess.run(["/bin/sh", "-c", args.launcher], env=env, cwd=args.cwd, capture_output=True, text=True, timeout=180)
    print(json.dumps({"exit": result.returncode, "stdout": result.stdout[-4000:],
                      "commands": agy_commands(Path(home), result.stdout)}))
    if result.returncode:
        print(result.stderr[-2000:])
    assert result.returncode == 0


def agy_commands(home: Path, stdout: str) -> list[str]:
    """What each command the turn ran printed, read from the conversation's transcript rather than from
    what the model says of it: the steps after each run_command call, as agy recorded them."""
    try:
        conversation = json.loads(stdout).get("conversation_id") or ""
    except ValueError:
        return []
    transcript = home / ".gemini/antigravity-cli/brain" / conversation / ".system_generated/logs/transcript.jsonl"
    if not conversation or not transcript.is_file():
        return []
    steps = [json.loads(line) for line in transcript.read_text(encoding="utf-8").splitlines() if line.strip()]
    return [str(step.get("content") or step.get("error") or "") for step in steps
            if step.get("type") == "GENERIC" and step.get("source") == "MODEL"]


if __name__ == "__main__":
    main()
