"""/provider sign-in, endpoints and /model through a PTY with local mocks; fabricated credentials only."""
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time

from mock_oauth import Issuer, jwt
from mock_providers import Mock
from test_interjections import Terminal, wait_for, ROOT, BIN, screen


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def base_env(home, **extra):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("NIB_", "CODEX_")) and not k.endswith("_API_KEY") and "proxy" not in k.lower()
           and k not in ("DISPLAY", "WAYLAND_DISPLAY", "SSH_CONNECTION", "SSH_TTY")}
    env.update(HOME=str(home), NIB_HOME=str(home / "nib"), CODEX_HOME=str(home / "codex"), TERM="xterm-256color")
    env.update(extra)
    return env


def visible(terminal):
    return "\n".join(screen(terminal.read(), 120, 32))


def until_visible(terminal, text, timeout=10):
    wait_for(lambda: text in visible(terminal), f"{text!r} on screen", timeout)


def store(home):
    return json.loads((home / "nib" / "auth.json").read_text())


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def logs(home):
    return [p for p in (home / "sessions").glob("*.jsonl") if not p.name.endswith(".calls.jsonl")]


def test_fresh_install(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    terminal = Terminal(tmp, base_env(home))
    try:
        until_visible(terminal, "Not signed in")
        until_visible(terminal, "No provider · /provider to sign in")
        assert "gpt-" not in visible(terminal)
        terminal.send("hello world\r")
        until_visible(terminal, "Add endpoint…")
        until_visible(terminal, "Choose a service")
        terminal.send("\x1b")
        wait_for(lambda: "Add endpoint…" not in visible(terminal), "menu closed")
        assert "hello world" in visible(terminal)
        assert not any('"role":"assistant"' in p.read_text() for p in logs(home))
        assert not (home / "nib" / "auth.json").exists()
    finally:
        terminal.close()
    result = subprocess.run([str(BIN), "ask", "hi"], cwd=tmp, env=base_env(home), capture_output=True, text=True, timeout=10)
    assert result.returncode != 0 and result.stderr == "nib: No provider · run nib login\n", result


def test_key_entry_and_model_list(tmp):
    tmp.mkdir()
    home = tmp / "home"
    (home / "nib").mkdir(parents=True)
    mock = Mock("responses", custom_run=True)
    (home / "nib" / "config.toml").write_text(f'[openai]\nbase_url = "{mock.url}"\n')
    terminal = Terminal(tmp, base_env(home))
    try:
        terminal.send("/provider openai\r")
        until_visible(terminal, "OpenAI API key")
        terminal.send("x")
        terminal.send("\x7f")
        terminal.send(mock.key)
        until_visible(terminal, "•" * len(mock.key))
        assert mock.key not in visible(terminal)
        terminal.send("\r")
        until_visible(terminal, "openai · gpt-6.2-sol")
        assert mock.key.encode() not in terminal.read()
        auth = home / "nib" / "auth.json"
        assert store(home) == {"keys": {"openai": mock.key}} and mode(auth) == 0o600
        config = (home / "nib" / "config.toml").read_text()
        assert 'provider = "openai"' in config and mock.key not in config
        terminal.send("hello\r")
        terminal.wait_turn("mock answer")
        terminal.send("/model ")
        until_visible(terminal, "gpt-6.1-terra")
        shown = visible(terminal)
        assert "gpt-6.2-sol" in shown and "gpt-6.2-astra" in shown and "current" in shown
        assert "claude" not in shown and "deepseek" not in shown
        terminal.send("\x15/status\r")
        until_visible(terminal, "key stored by nib")
        terminal.send("/provider logout openai\r")
        until_visible(terminal, "OpenAI · signed out")
        assert store(home) == {"keys": {}}
        terminal.send("again after logout\r")
        until_visible(terminal, "Add endpoint…")
        terminal.send("\x1b")
        wait_for(lambda: "Add endpoint…" not in visible(terminal), "menu closed")
        assert not mock.errors, mock.errors
    finally:
        terminal.close()
        mock.close()


def test_child_agent_uses_stored_key(tmp):
    tmp.mkdir()
    home = tmp / "home"
    (home / "nib").mkdir(parents=True)
    mock = Mock("responses", custom_run=True)
    (home / "nib" / "config.toml").write_text(f'provider = "openai"\n[openai]\nbase_url = "{mock.url}"\n')
    (home / "nib" / "auth.json").write_text(json.dumps({"keys": {"openai": mock.key}}))
    try:
        result = subprocess.run([str(BIN), "ask", "delegate"], cwd=tmp, env=base_env(home), capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result
        assert "child answer" in result.stdout + result.stderr or any("child" in json.dumps(r[2]) for r in mock.requests), result
        assert len(mock.requests) >= 3 and not mock.errors, mock.errors
        assert mock.key not in result.stdout + result.stderr
    finally:
        mock.close()


def test_add_endpoint(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    mock = Mock("chat_completions", models=[{"id": "m-one", "context_window": 32768}, {"id": "m-two"}])
    plain = Mock("chat_completions", key="")
    terminal = Terminal(tmp, base_env(home))
    config = home / "nib" / "config.toml"
    try:
        terminal.send("/provider +\r")
        until_visible(terminal, "Add endpoint 1/4 · Name")
        terminal.send("openai\r")
        until_visible(terminal, "Name is taken by a built-in service")
        terminal.send("\x15local1\r")
        until_visible(terminal, "Add endpoint 2/4 · Base URL")
        terminal.send("localhost\r")
        until_visible(terminal, "Base URL must start with http:// or https://")
        terminal.send("\x15" + mock.url + "/\r")
        until_visible(terminal, "Add endpoint 3/4")
        terminal.send(mock.key)
        until_visible(terminal, "•" * len(mock.key))
        assert mock.key not in visible(terminal)
        terminal.send("\r")
        until_visible(terminal, "Add endpoint 4/4")
        terminal.send("\r")
        until_visible(terminal, "Choose a model")
        until_visible(terminal, "32.7k tokens")
        assert "m-two" in visible(terminal)
        assert not config.exists()
        terminal.send("\r")
        until_visible(terminal, "local1 · m-one")
        text = config.read_text()
        assert text.startswith('provider = "local1"\n') and "[providers.local1]" in text
        assert 'protocol = "chat_completions"' in text and f'base_url = "{mock.url}"' in text
        assert 'model = "m-one"' in text and "context_window = 32768" in text and mock.key not in text
        assert store(home) == {"keys": {"local1": mock.key}} and mode(home / "nib" / "auth.json") == 0o600
        assert mock.gets[0][0] == "/models" and {k.lower(): v for k, v in mock.gets[0][1].items()}["authorization"] == f"Bearer {mock.key}"
        assert mock.key.encode() not in terminal.read()
        terminal.send("hello\r")
        terminal.wait_turn("mock answer")
        assert mock.requests[-1][2]["model"] == "m-one" and not mock.errors
        terminal.send("/model ")
        until_visible(terminal, "m-one")
        assert "m-two" not in visible(terminal) and "gpt-6" not in visible(terminal)
        terminal.send("\x15")
        # A failed listing asks for the model id and window as text; Esc leaves nothing behind.
        before = config.read_text()
        terminal.send("/provider +\r")
        until_visible(terminal, "Add endpoint 1/4")
        terminal.send("local2\r" + plain.url + "\r\r")
        until_visible(terminal, "Add endpoint 4/4")
        terminal.send("\x1b")
        wait_for(lambda: "Add endpoint 4/4" not in visible(terminal), "form closed")
        assert config.read_text() == before and "local2" not in json.dumps(store(home))
        terminal.send("/provider +\r")
        until_visible(terminal, "Add endpoint 1/4")
        terminal.send("local2\r" + plain.url + "\r\r\r")
        until_visible(terminal, "Could not list models · type the model id")
        until_visible(terminal, "Add endpoint · Model id")
        terminal.send("typed-model\r")
        until_visible(terminal, "Context window · default 128000")
        terminal.send("\r")
        until_visible(terminal, "local2 · typed-model")
        text = config.read_text()
        assert "[providers.local2]" in text and "context_window = 128000" in text
        assert "local2" not in json.dumps(store(home))
        assert plain.gets and plain.gets[0][0] == "/models"
        terminal.send("hello again\r")
        terminal.wait_turn("mock answer")
        assert plain.requests[-1][2]["model"] == "typed-model" and not plain.errors
    finally:
        terminal.close()
        mock.close()
        plain.close()


def opener(directory, log, silent=False):
    directory.mkdir()
    script = directory / ("open" if sys.platform == "darwin" else "xdg-open")
    if silent:
        script.write_text(f'#!/bin/sh\necho "$1" >> "{log}"\nexit 0\n')
    else:
        script.write_text(f"""#!/bin/sh
echo "$1" >> "{log}"
python3 -c '
import sys, time, urllib.parse, urllib.request
url = sys.argv[1]
q = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
urllib.request.urlopen(url, timeout=5).read()
time.sleep(0.2)
urllib.request.urlopen(q["redirect_uri"][0] + "?code=browser-code&state=" + urllib.parse.quote(q["state"][0]), timeout=10).read()
' "$1" >/dev/null 2>&1 &
exit 0
""")
    script.chmod(0o755)
    return directory


def test_codex_browser_login(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    issuer = Issuer()
    port = free_port()
    log = tmp / "opened.log"
    env = base_env(home, NIB_AUTH_ISSUER=issuer.url, NIB_AUTH_PORT=str(port), DISPLAY=":0",
                   PATH=f"{opener(tmp / 'bin', log)}:{os.environ['PATH']}")
    terminal = Terminal(tmp, env)
    try:
        terminal.send("/provider codex\r")
        until_visible(terminal, "Codex · signed in · ChatGPT Plus")
        query = issuer.authorizations[0]
        assert query["response_type"] == "code" and query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
        assert query["code_challenge_method"] == "S256" and "offline_access" in query["scope"]
        assert query["redirect_uri"] == f"http://127.0.0.1:{port}/auth/callback"
        assert log.read_text().startswith(issuer.url + "/oauth/authorize?")
        tokens = store(home)["tokens"]
        assert tokens["account_id"] == "acc-mock" and tokens["refresh_token"] == "issued-refresh"
        assert mode(home / "nib" / "auth.json") == 0o600
        assert 'provider = "codex"' in (home / "nib" / "config.toml").read_text()
        terminal.send("/provider ")
        until_visible(terminal, "signed in · ChatGPT Plus · current")
        terminal.send("\x15/provider logout codex\r")
        until_visible(terminal, "Codex · signed out")
        assert "tokens" not in store(home)
    finally:
        terminal.close()
    # Esc while waiting cancels and frees the callback port.
    quiet = base_env(home, NIB_AUTH_ISSUER=issuer.url, NIB_AUTH_PORT=str(port), DISPLAY=":0",
                     PATH=f"{opener(tmp / 'quiet', tmp / 'quiet.log', silent=True)}:{os.environ['PATH']}")
    terminal = Terminal(tmp, quiet)
    try:
        terminal.send("/provider codex\r")
        until_visible(terminal, "Waiting for ChatGPT sign-in")
        terminal.send("\x1b")
        wait_for(lambda: "Waiting for ChatGPT sign-in" not in visible(terminal), "waiting line gone", 15)
        assert "tokens" not in store(home)
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", port))
    finally:
        terminal.close()
        issuer.close()


def test_codex_device_login(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    issuer = Issuer(polls_before_approval=1)
    env = base_env(home, NIB_AUTH_ISSUER=issuer.url, NIB_AUTH_NO_BROWSER="1")
    terminal = Terminal(tmp, env)
    try:
        terminal.send("/provider codex\r")
        until_visible(terminal, f"Open {issuer.url}/codex/device and enter code ABCD-1234")
        until_visible(terminal, "Codex · signed in · ChatGPT Plus", 20)
        assert store(home)["tokens"]["refresh_token"] == "issued-refresh"
        assert not issuer.authorizations
    finally:
        terminal.close()
    issuer.polls_left = 1
    (home / "nib" / "auth.json").unlink()
    result = subprocess.run([str(BIN), "login", "codex", "--device"], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result
    assert f"Open {issuer.url}/codex/device\nEnter code ABCD-1234\n" in result.stdout
    assert result.stdout.endswith("Codex · signed in · ChatGPT Plus\n")
    assert store(home)["tokens"]["account_id"] == "acc-mock"
    issuer.close()


def test_codex_refresh(tmp):
    tmp.mkdir()
    issuer = Issuer()
    port = free_port()
    requests = tmp / "requests.jsonl"
    server = subprocess.Popen([sys.executable, str(ROOT / "tests/mock_codex.py"), str(port), str(requests)], stdout=subprocess.DEVNULL)
    try:
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, "mock codex")
        expired = jwt(exp=int(time.time()) - 60)
        for name, location, extra in (("nib", "home/nib/auth.json", {}), ("cli", "home/codex/auth.json", {"OPENAI_API_KEY": None})):
            home = tmp / name / "home"
            home.mkdir(parents=True)
            path = tmp / name / location
            path.parent.mkdir(parents=True, exist_ok=True)
            refresh = "old-refresh" if name == "nib" else "cli-refresh"
            path.write_text(json.dumps({**extra, "tokens": {"access_token": expired, "id_token": expired, "account_id": "acc-mock", "refresh_token": refresh}}))
            original_mode = mode(path)
            env = base_env(home, NIB_HOME=str(home / "nib"), CODEX_HOME=str(home / "codex"), NIB_PROVIDER="codex",
                           NIB_CODEX_TRANSPORT="sse", NIB_BASE_URL=f"http://127.0.0.1:{port}", NIB_AUTH_ISSUER=issuer.url)
            before = len(requests.read_text().splitlines()) if requests.exists() else 0
            result = subprocess.run([str(BIN), "ask", "plain text"], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result
            sent = [json.loads(line) for line in requests.read_text().splitlines()][before:]
            assert sent and all(r["headers"]["authorization"] != f"Bearer {expired}" for r in sent), sent
            assert sent[0]["headers"]["authorization"].startswith("Bearer e30.")
            saved = json.loads(path.read_text())
            assert saved["tokens"]["refresh_token"] == "refreshed-refresh" and saved["tokens"]["access_token"] != expired
            assert "last_refresh" in saved and all(k in saved for k in extra)
            assert mode(path) == (0o600 if name == "nib" else original_mode)
            assert issuer.requests[-1][2]["refresh_token"] == refresh
            assert issuer.requests[-1][1].startswith("application/json")
    finally:
        server.terminate()
        server.wait()
        issuer.close()


def test_cli_login_and_logout(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    env = base_env(home)
    run = lambda *args, **kw: subprocess.run([str(BIN), *args], cwd=tmp, env=kw.get("env", env), capture_output=True, text=True, timeout=10, input=kw.get("input"))
    listing = run("login", input="")
    assert listing.returncode != 0 and "Codex" in listing.stdout and "xAI" in listing.stdout
    done = run("login", "anthropic", input="fake-cli-key\n")
    assert done.returncode == 0 and done.stdout.endswith("Anthropic · key stored\n") and "fake-cli-key" not in done.stdout + done.stderr
    assert store(home) == {"keys": {"anthropic": "fake-cli-key"}} and mode(home / "nib" / "auth.json") == 0o600
    numbered = run("login", input="5\nfake-xai\n")
    assert "xAI · key stored" in numbered.stdout and store(home)["keys"]["xai"] == "fake-xai"
    assert run("login", "nope", input="").returncode != 0
    assert run("login", "openai", input="\n").returncode != 0
    out = run("logout", "anthropic", env={**env, "ANTHROPIC_API_KEY": "from-env"})
    assert out.stdout == "Anthropic · signed out · key still set in ANTHROPIC_API_KEY\n", out
    assert "anthropic" not in store(home)["keys"]
    assert run("logout", "anthropic").stdout == "Anthropic · nothing stored by nib\n"
    help_text = run("--help").stdout
    assert "nib login [service]" in help_text and "nib logout <service>" in help_text


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-login-") as directory:
        for name, test in sorted((n, f) for n, f in globals().items() if n.startswith("test_")):
            test(Path(directory) / name)
            print(f"{name}: ok")
