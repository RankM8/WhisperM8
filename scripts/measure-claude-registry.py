#!/usr/bin/env python3
# Misst, wann die Claude-CLI ihren Registry-Eintrag `<config-dir>/sessions/<pid>.json`
# schreibt und welche Sitzungs-ID darin steht — für einen frischen Start, `--resume`
# und `--resume --fork-session`. Vergleicht mit der ID aus dem SessionStart-Hook.
# Grundlage der Rückfall-Bindung (AgentSessionStore+FallbackBinding.swift).
#
#   python3 -I scripts/measure-claude-registry.py <leerer-ordner> frisch|resume|fork
#
# Läuft mit eigenem CLAUDE_CONFIG_DIR unter <leerer-ordner>, ohne Login und ohne
# Turn: berührt weder ~/.claude noch die App. Nach CLI-Updates wiederholen.
import json, os, pty, select, signal, sys, time

base = sys.argv[1]; mode = sys.argv[2]
cfg = os.path.join(base, 'cfg'); work = os.path.join(base, 'work')
os.makedirs(os.path.join(cfg, 'sessions'), exist_ok=True); os.makedirs(work, exist_ok=True)
work = os.path.realpath(work)
src = '11111111-2222-4333-8444-555555555555'
proj = os.path.join(cfg, 'projects', work.replace('/', '-').replace('.', '-'))
os.makedirs(proj, exist_ok=True)
now = '2026-11-13T12:00:00.000Z'
lines = [
  {"parentUuid": None, "isSidechain": False, "type": "user", "message": {"role": "user", "content": "Hallo"},
   "uuid": "aaaaaaaa-0000-4000-8000-000000000001", "timestamp": now, "userType": "external", "entrypoint": "cli",
   "cwd": work, "sessionId": src, "version": "2.1.323"},
  {"parentUuid": "aaaaaaaa-0000-4000-8000-000000000001", "isSidechain": False, "type": "assistant",
   "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
               "content": [{"type": "text", "text": "Hallo zurück"}], "stop_reason": "end_turn", "stop_sequence": None,
               "usage": {"input_tokens": 1, "output_tokens": 1}},
   "uuid": "aaaaaaaa-0000-4000-8000-000000000002", "timestamp": now, "userType": "external", "entrypoint": "cli",
   "cwd": work, "sessionId": src, "version": "2.1.323"},
]
with open(os.path.join(proj, src + '.jsonl'), 'w') as f:
    for l in lines: f.write(json.dumps(l) + '\n')
cj = os.path.join(cfg, '.claude.json')
if not os.path.exists(cj):
    json.dump({"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5,
               "projects": {work: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}}}, open(cj, 'w'))
args = {'frisch': [], 'resume': ['--resume', src], 'fork': ['--resume', src, '--fork-session']}[mode]
hooklog = os.path.join(base, 'hooks.jsonl')
settings = os.path.join(base, 'settings.json')
json.dump({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": f"cat >> {hooklog}; echo >> {hooklog}"}]}]}}, open(settings, 'w'))
args = ['--settings', settings] + args
env = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'ANTHROPIC', 'WHISPERM8', 'CCP_'))}
env['CLAUDE_CONFIG_DIR'] = cfg; env['TERM'] = 'xterm-256color'
pid, fd = pty.fork()
if pid == 0:
    os.chdir(work); os.execvpe('claude', ['claude'] + args, env)
t0 = time.time(); seen = {}; out = b''
while time.time() - t0 < 12:
    r, _, _ = select.select([fd], [], [], 0.02)
    if r:
        try: out += os.read(fd, 65536)
        except OSError: break
    p = os.path.join(cfg, 'sessions', f'{pid}.json')
    if os.path.exists(p):
        try: d = json.load(open(p))
        except Exception: continue
        key = (d.get('sessionId'), d.get('status'))
        if key not in seen:
            seen[key] = round(time.time() - t0, 3)
            print(f'{seen[key]:7.3f}s registry sessionId={d.get("sessionId")} status={d.get("status")} kind={d.get("kind")}', flush=True)
os.kill(pid, signal.SIGTERM)
end = time.time() + 1.0
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: os.read(fd, 65536)
        except OSError: break
os.close(fd)
try: os.kill(pid, signal.SIGKILL)
except ProcessLookupError: pass
try: os.waitpid(pid, 0)
except ChildProcessError: pass
files = sorted(os.listdir(proj))
hooks = []
if os.path.exists(hooklog):
    for l in open(hooklog):
        l = l.strip()
        if l:
            d = json.loads(l); hooks.append((d.get('source'), d.get('session_id')))
print('mode', mode, 'quelle', src[:8], 'transcripts', [f[:8] for f in files], 'hooks', hooks)
