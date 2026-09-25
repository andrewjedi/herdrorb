#!/usr/bin/env python3
"""herdrorb provider bridge: bounded reads and session-scoped Claude telemetry.
Uses Python's standard library, like Herdr's own provider integrations.
"""
import base64
import glob
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = os.path.expanduser('~/Library/Application Support/herdrorb/provider-bridge')

def atomic_json(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def session_id(value):
    return str(uuid.UUID(value))

def report_session(payload):
    pane = os.environ.get('HERDR_PANE_ID')
    path = os.environ.get('HERDR_SOCKET_PATH')
    if not pane or not path:
        return
    params = {'pane_id': pane, 'source': 'herdrorb:claude', 'agent': 'claude',
              'agent_session_id': session_id(payload['session_id']), 'seq': time.time_ns()}
    if payload.get('transcript_path'):
        params['agent_session_path'] = payload['transcript_path']
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(0.5)
        client.connect(path)
        client.sendall((json.dumps({'id': str(uuid.uuid4()), 'method': 'pane.report_agent_session', 'params': params}) + '\n').encode())
        client.recv(4096)

def statusline(previous):
    raw = sys.stdin.buffer.read(2 * 1024 * 1024)
    try:
        payload = json.loads(raw)
        sid = session_id(payload['session_id'])
        # Store only usage/model, never prompts, cwd, account details, or tool data.
        selected = {key: payload.get(key) for key in ['session_id', 'model', 'context_window']}
        selected['herdrorb_observed_at'] = time.time()
        atomic_json(os.path.join(ROOT, 'usage', sid + '.json'), selected)
        try:
            report_session(payload)
        except Exception:
            pass
        # Bounded retention of telemetry files (not the provider transcripts).
        files = glob.glob(os.path.join(ROOT, 'usage', '*.json'))
        for old in sorted(files, key=os.path.getmtime, reverse=True)[100:]:
            try:
                os.unlink(old)
            except OSError:
                pass
    except Exception:
        payload = {}
    if previous:
        command = base64.b64decode(previous).decode()
        try:
            result = subprocess.run(command, shell=True, input=raw, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=5)
            sys.stdout.buffer.write(result.stdout)
        except Exception:
            pass
    else:
        value = (payload.get('context_window') or {}).get('used_percentage')
        print('Context: {}% used'.format(value) if isinstance(value, (int, float)) else 'Context unavailable')

def install(cwd):
    if not os.path.isabs(cwd) or not os.path.isdir(cwd):
        raise ValueError('A valid project folder is required to connect Claude telemetry')
    project = os.path.join(cwd, '.claude')
    target = os.path.join(project, 'settings.local.json')
    effective = {}
    config = os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude'))
    for path in [os.path.join(config, 'settings.json'), os.path.join(project, 'settings.json'), target]:
        if os.path.exists(path):
            with open(path) as source:
                settings = json.load(source)
            if 'statusLine' in settings:
                effective = settings['statusLine']
    existing = {}
    if os.path.exists(target):
        with open(target) as source:
            existing = json.load(source)
    command = effective.get('command', '') if isinstance(effective, dict) else ''
    if 'provider_bridge.py' in command and 'statusline' in command:
        return {'installed': True}
    if command and effective.get('type') != 'command':
        raise ValueError('Unsupported existing status line; it has been left unchanged')
    import shlex
    previous = base64.b64encode(command.encode()).decode()
    settings = dict(effective) if isinstance(effective, dict) else {}
    settings.update(type='command', command=' '.join(shlex.quote(v) for v in [sys.executable, os.path.abspath(__file__), 'statusline', previous]))
    # Preserve every other setting, including status-line padding and user hooks.
    existing['statusLine'] = settings
    if os.path.exists(target) and not os.path.exists(target + '.herdrorb-backup'):
        import shutil
        shutil.copy2(target, target + '.herdrorb-backup')
        os.chmod(target + '.herdrorb-backup', 0o600)
    atomic_json(target, existing)
    return {'installed': True}

def read(request):
    reference = request['reference']
    cursor = request['cursor']
    path = cursor.get('path') or (reference['value'] if reference['kind'] == 'path' else '')
    if not path:
        sid = session_id(reference['value'])
        if reference['agent'] == 'codex':
            root = os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex'))
            matches = glob.glob(os.path.join(root, 'sessions', '**', '*-' + sid + '.jsonl'), recursive=True)
        else:
            root = os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude'))
            matches = glob.glob(os.path.join(root, 'projects', '*', sid + '.jsonl'))
        if len(matches) != 1:
            raise ValueError('The exact provider transcript could not be located')
        path = matches[0]
    if not os.path.isabs(path) or not path.endswith('.jsonl'):
        raise ValueError('Invalid transcript path')
    with open(path, 'rb') as source:
        import stat
        attributes = os.fstat(source.fileno())
        if not stat.S_ISREG(attributes.st_mode):
            raise ValueError('Transcript is not a regular file')
        identity = '{}:{}'.format(attributes.st_dev, attributes.st_ino)
        offset = cursor.get('offset', 0)
        if identity != cursor.get('identity') or offset > attributes.st_size:
            offset = 0
        source.seek(offset)
        data = source.read(1024 * 1024)
        if data and b'\n' not in data:
            data += source.read(7 * 1024 * 1024)
    return {'path': path, 'identity': identity, 'offset': offset, 'size': attributes.st_size,
            'data': base64.b64encode(data).decode()}

def dispatch(arguments):
    mode = arguments[0]
    if mode == 'install':
        return install(arguments[1])
    if mode == 'read':
        return read(json.loads(base64.b64decode(arguments[1])))
    if mode == 'usage':
        path = os.path.join(ROOT, 'usage', session_id(arguments[1]) + '.json')
        return json.load(open(path)) if os.path.exists(path) else {}
    raise ValueError('Unknown bridge operation')

if __name__ == '__main__':
    if sys.argv[1] == 'serve':
        for request in sys.stdin:
            try:
                print(json.dumps({'result': dispatch(json.loads(request))}), flush=True)
            except Exception as error:
                print(json.dumps({'error': str(error)}), flush=True)
    elif sys.argv[1] == 'statusline':
        statusline(sys.argv[2] if len(sys.argv) > 2 else '')
    else:
        try:
            print(json.dumps(dispatch(sys.argv[1:])))
        except Exception as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
