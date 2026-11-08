#!/usr/bin/env python3
"""Check explicit evaluation continuation using synthetic loopback requests only."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
CASES = ROOT / 'Tests/PromptEvaluation/cases.json'
SUITE = json.loads(CASES.read_text())
BY_SOURCE = {(case['source'], case['intent']): case for case in SUITE['cases']}
CHECKS = []
STATE = {'calls': [], 'failure_at': None, 'errors': []}


def check(condition, assertion):
    CHECKS.append({'assertion': assertion, 'passed': bool(condition)})
    if not condition:
        raise AssertionError(assertion)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            source = body['input'] if self.path == '/responses' else body['messages'][-1]['content']
            instructions = body['instructions'] if self.path == '/responses' else (
                body['system'] if self.path == '/messages' else body['messages'][0]['content'])
            intent = 'optimize' if instructions.startswith('Rewrite') else 'translate'
            case = BY_SOURCE[(source, intent)]
            STATE['calls'].append(case['id'])
            text = 'SYNTHETIC RESULT\n' + '\n'.join(case['requiredLiterals'])
            if len(STATE['calls']) == STATE['failure_at']:
                payload, status = {'error': {'message': 'synthetic rate limit'}}, 429
            elif self.path == '/responses':
                payload, status = {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': text}]}]}, 200
            elif self.path == '/messages':
                payload, status = {'type': 'message', 'role': 'assistant', 'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': text}]}, 200
            else:
                payload, status = {'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': text}}]}, 200
        except Exception as error:
            STATE['errors'].append(str(error))
            payload, status = {'error': {'message': 'synthetic fixture error'}}, 500
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    subprocess.run(['swift', 'build', '--product', 'ProviderCheck'], cwd=ROOT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'ProviderCheck'
    parent = ROOT / '.build/staged-implementation-2026-10-07'
    parent.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}'
    completed = False
    try:
        with tempfile.TemporaryDirectory(prefix='resume-contract-', dir=parent) as temporary:
            directory = Path(temporary)

            def reset(failure_at=None):
                STATE.update(calls=[], failure_at=failure_at, errors=[])

            def run(name, protocol='chatCompletions', extra=(), mode=None):
                out = directory / name
                command = [str(binary), '--cases', str(CASES), '--output', str(out)]
                command += mode or ['--mock-url', url, '--format', protocol]
                result = subprocess.run(command + list(extra), cwd=ROOT, capture_output=True, text=True)
                report_path = out / 'report.json'
                report = json.loads(report_path.read_text()) if report_path.exists() else None
                return result, report, report_path

            for protocol in ['chatCompletions', 'responses', 'anthropicMessages']:
                reset(failure_at=4)
                result, stopped, old_path = run(protocol + '-stopped', protocol)
                check(result.returncode == 1 and stopped['requestCount'] == 4 and len(STATE['calls']) == 4,
                      f'{protocol}: prepare a stopped synthetic baseline after three outputs')
                original = old_path.read_bytes()
                reset()
                extra = ['--resume-report', str(old_path), '--request-budget', '64']
                result, resumed, resumed_path = run(protocol + '-resumed', protocol, extra)
                check(result.returncode == 0 and not STATE['errors'] and STATE['calls'] == [c['id'] for c in SUITE['cases'][3:]],
                      f'{protocol}: only the failed and unattempted 29 cases run')
                check(resumed['requestCount'] == 33 and resumed['results'][:3] == stopped['results'][:3]
                      and resumed['resumedFromRunID'] == stopped['runID'] and resumed['resumedRequestCount'] == 4
                      and old_path.read_bytes() == original and resumed['semanticStatus'] == 'requiresHumanReview',
                      f'{protocol}: preserve prefix and old evidence; count the failed attempt without a quality verdict')
                if protocol == 'chatCompletions':
                    failure_path, baseline_path = old_path, resumed_path
                    failure_report = stopped

            def reject(name, path=failure_path, extra=(), mode=None):
                reset()
                result, report, _ = run(name, extra=['--resume-report', str(path), '--request-budget', '64', *extra], mode=mode)
                check(result.returncode != 0 and not STATE['calls'] and report is None,
                      name + ': reject before requests or new report')

            reset(failure_at=1)
            result, stopped_again, second_path = run('stopped-again', extra=['--resume-report', str(failure_path), '--request-budget', '64'])
            check(result.returncode == 1 and STATE['calls'] == [SUITE['cases'][3]['id']]
                  and stopped_again['requestCount'] == 5 and stopped_again['results'][:3] == failure_report['results'][:3],
                  'a manual continuation fails once and stops; no automatic retry')
            reset()
            result, chained, _ = run('chained', extra=['--resume-report', str(second_path), '--request-budget', '64'])
            check(result.returncode == 0 and chained['requestCount'] == 34 and len(STATE['calls']) == 29
                  and chained['resumedFromRunID'] == stopped_again['runID'],
                  'a second manual continuation retains both failed attempts')

            mutations = {
                'changed-model': lambda r: r['model'].update(name='different-model'),
                'changed-route': lambda r: r['model'].update(routeRevision='different-route'),
                'changed-template': lambda r: r['results'][5].update(templateRevision='f' * 64),
                'changed-matrix': lambda r: r['suite']['cases'][5].update(source='different synthetic source'),
                'sparse-output': lambda r: r['results'][6].update(output='unexpected completed suffix'),
                'incorrect-literal-evidence': lambda r: r['results'][0].update(missingLiterals=['invented']),
                'undercounted-attempts': lambda r: r.update(requestCount=3),
                'completed-resume-source': lambda r: r.update(status='completed'),
            }
            for name, mutate in mutations.items():
                changed = json.loads(json.dumps(failure_report))
                mutate(changed)
                path = directory / (name + '.json')
                path.write_text(json.dumps(changed))
                reject(name, path)
            reject('offline-resume', mode=['--dry-run'])
            reset()
            result, report, _ = run('missing-budget', extra=['--resume-report', str(failure_path)])
            check(result.returncode != 0 and not STATE['calls'] and report is None, 'resume requires an explicit request budget')
            reset()
            result, report, _ = run('insufficient-budget', extra=['--resume-report', str(failure_path), '--request-budget', '32'])
            check(result.returncode != 0 and not STATE['calls'] and report is None, 'budget includes the first failed attempt')
            reset()
            result, report, _ = run('candidate-budget', extra=['--label', 'candidate', '--baseline-report', str(baseline_path), '--request-budget', '64'])
            check(result.returncode != 0 and not STATE['calls'] and report is None, '33 baseline attempts plus 32 candidate calls exceed 64; no partial candidate run')
            reset()
            result, report, _ = run('candidate-default-budget', extra=['--label', 'candidate', '--baseline-report', str(baseline_path)])
            check(result.returncode != 0 and not STATE['calls'] and report is None, 'omitting the budget still applies the default total of 64')
            reset(failure_at=4)
            result, stopped_candidate, candidate_path = run('candidate-stopped', extra=['--label', 'candidate', '--baseline-report', str(baseline_path), '--request-budget', '70'])
            check(result.returncode == 1 and stopped_candidate['requestCount'] == 4, 'prepare a synthetic stopped candidate for baseline accounting')
            reject('candidate-resume-without-baseline', candidate_path, ['--label', 'candidate'])
            reject('candidate-resume-total-budget', candidate_path, ['--label', 'candidate', '--baseline-report', str(baseline_path)])
            tampered = json.loads(baseline_path.read_text())
            tampered['requestCount'] = 0
            low_path = directory / 'underreported-baseline.json'
            low_path.write_text(json.dumps(tampered))
            reset()
            result, report, _ = run('underreported-baseline', extra=['--label', 'candidate', '--baseline-report', str(low_path)])
            check(result.returncode != 0 and not STATE['calls'] and report is None, 'a complete baseline cannot report fewer than 32 attempts')
            existing = directory / 'existing-other-evidence'
            existing.mkdir()
            marker = existing / 'marker.txt'
            marker.write_text('synthetic prior evidence')
            reset()
            result, report, _ = run(existing.name, extra=['--resume-report', str(failure_path), '--request-budget', '64'])
            check(result.returncode != 0 and not STATE['calls'] and report is None and marker.read_text() == 'synthetic prior evidence', 'existing output with other files is refused and preserved')
            completed = True
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        summary = {'completed': completed, 'checks': CHECKS, 'remoteModelRequests': 0, 'semanticQuality': 'notEvaluated'}
        (parent / 'evaluation-resume-contract-report.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(CHECKS)}/{len(CHECKS)} continuation checks passed; loopback only')


if __name__ == '__main__':
    main()
