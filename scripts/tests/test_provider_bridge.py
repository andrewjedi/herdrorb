import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'Sources/HerdrOrb/Resources/provider_bridge.py'

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.project = self.home / "project ' with spaces"
        self.project.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), CLAUDE_CONFIG_DIR=str(self.home / '.claude'))
    def tearDown(self):
        self.temp.cleanup()
    def run_bridge(self, *args, payload=None):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                input=json.dumps(payload) if payload else '', text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout
    def test_install_preserves_effective_command_settings_and_idempotency(self):
        settings = self.project / '.claude'
        settings.mkdir()
        original = {'permissions': {'allow': ['Read']}, 'statusLine': {'type': 'command', 'command': 'printf original', 'padding': 3}}
        target = settings / 'settings.local.json'
        target.write_text(json.dumps(original))
        self.run_bridge('install', str(self.project))
        first = target.read_text()
        current = json.loads(first)
        self.assertEqual(current['permissions'], original['permissions'])
        self.assertEqual(current['statusLine']['padding'], 3)
        self.assertIn('statusline', current['statusLine']['command'])
        self.assertEqual(json.loads(Path(str(target)+'.herdrorb-backup').read_text()), original)
        self.run_bridge('install', str(self.project))
        self.assertEqual(target.read_text(), first)
    def test_statusline_passes_stdin_to_original_and_saves_only_usage(self):
        sid = 'abcdef12-3456-7890-abcd-ef1234567890'
        payload = {'session_id': sid, 'model': {'id': 'model'}, 'context_window': {'used_percentage': 25}, 'cwd': '/private', 'cost': {'total_cost_usd': 2}}
        prior = base64.b64encode(b'printf "existing display"').decode()
        output = self.run_bridge('statusline', prior, payload=payload)
        self.assertEqual(output, 'existing display')
        usage = json.loads(self.run_bridge('usage', sid))
        self.assertEqual(usage['session_id'], sid)
        self.assertNotIn('cwd', usage)
        self.assertNotIn('cost', usage)
        self.assertIn('herdrorb_observed_at', usage)
        file = self.home / 'Library/Application Support/herdrorb/provider-bridge/usage' / (sid+'.json')
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
    def test_read_partial_and_appended_bytes_with_exact_session_path(self):
        file = self.project / 'test.jsonl'
        file.write_bytes(b'one\ntwo')
        request = {'reference': {'agent': 'claude', 'kind': 'path', 'value': str(file)}, 'cursor': {'offset': 0, 'identity': ''}}
        encoded = base64.b64encode(json.dumps(request).encode()).decode()
        first = json.loads(self.run_bridge('read', encoded))
        self.assertEqual(base64.b64decode(first['data']), b'one\ntwo')
        request['cursor'].update(offset=4, identity=first['identity'])
        file.write_bytes(b'one\ntwo\n')
        second = json.loads(self.run_bridge('read', base64.b64encode(json.dumps(request).encode()).decode()))
        self.assertEqual(base64.b64decode(second['data']), b'two\n')
    def test_retained_worker_serves_multiple_requests(self):
        sid = 'abcdef12-3456-7890-abcd-ef1234567890'
        requests = '\n'.join(json.dumps(['usage', sid]) for _ in range(3))+'\n'
        result = subprocess.run([sys.executable, str(SCRIPT), 'serve'], env=self.env, input=requests, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()], [{'result': {}}]*3)
    def test_invalid_json_settings_are_not_replaced(self):
        settings = self.project / '.claude'
        settings.mkdir()
        target = settings / 'settings.local.json'
        target.write_text('{broken')
        result = subprocess.run([sys.executable, str(SCRIPT), 'install', str(self.project)], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), '{broken')

if __name__ == '__main__':
    unittest.main()
