"""Real helper subprocess checks against task-owned fake CLIs; no TTY or host UI."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
helper = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'promptbridge-editor'
with tempfile.TemporaryDirectory(prefix='promptbridge-helper-') as raw:
    directory = Path(raw)
    env = {'PATH': str(directory), 'VISUAL': 'original-editor', 'EDITOR': 'another-editor',
           'CODEX_HOME': str(directory / 'custom codex'), 'CLAUDE_CONFIG_DIR': str(directory / 'custom claude'),
           'CLAUDE_CODE_TMPDIR': str(directory / 'custom temp')}
    for name in ['codex', 'claude']:
        cli = directory / name
        cli.write_text('#!/bin/sh\nprintf "%s\\n" "$VISUAL" "$EDITOR" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$CLAUDE_CODE_TMPDIR" "$@"\nexit 17\n')
        cli.chmod(0o700)
        result = subprocess.run([str(helper), '--launch', name, '--', '--version', 'arg with spaces'],
                                cwd=directory, env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 17, (name, result)
        assert result.stdout.splitlines() == ['original-editor', 'another-editor', env['CODEX_HOME'], env['CLAUDE_CONFIG_DIR'], env['CLAUDE_CODE_TMPDIR'], '--version', 'arg with spaces'], result
    assert subprocess.run([str(helper), '--help'], env=env, capture_output=True, timeout=5).returncode == 0
    assert subprocess.run([str(helper), '--launch', 'unknown', '--'], env=env, capture_output=True, timeout=5).returncode == 2
    source = directory / 'not-connected.md'
    source.write_text('unchanged synthetic text\n')
    refused = subprocess.run([str(helper), str(source)], cwd=directory, env=env, capture_output=True, timeout=5)
    assert refused.returncode == 1
    assert source.read_text() == 'unchanged synthetic text\n'
    assert sorted(p.name for p in directory.iterdir()) == ['claude', 'codex', 'not-connected.md']
print('CLI helper subprocess checks passed: argv/environment/exit passthrough, help, invalid launch, unconnected refusal')
