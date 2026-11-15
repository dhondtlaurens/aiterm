"""Drive real Codex with scripted local Responses through an AiTerm worker launcher.

Only temporary CODEX_HOME/config and synthetic git repositories are used. No account or model.
The caller writes launcher/agent files through WorkerGuardLaunch, so this checks the actual PATH
shims rather than a second implementation of their environment.
"""
import argparse
import json
import os
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
    args = parser.parse_args()
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


if __name__ == "__main__":
    main()
