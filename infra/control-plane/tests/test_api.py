from concurrent.futures import ThreadPoolExecutor
import json
import time

from fastapi.testclient import TestClient
import pytest

from crew_control.app import Settings, create_app
from crew_control.artifacts import ArtifactError
from test_artifacts import make_archive

CASE = dict(id='day1', day=1, title='Accessibility', prompt='Improve the proposed interface.',
            source_repo='wowlocal/crew18-sim', base_commit='a' * 40,
            project='PodlodkaDive.xcodeproj', scheme='PodlodkaDive', runtime_version='26.5', is_open=True)


@pytest.fixture
def setup(tmp_path):
    verified = []
    def provenance(path, **policy):
        verified.append(policy)
        return {'provider': 'test-only'}
    app = create_app(Settings(tmp_path, 'crew/infra/.github/workflows/build.yml', 'b' * 40), provenance)
    tokens = {}
    for name, role in [('admin', 'admin'), ('alice', 'participant'), ('bob', 'participant'),
                       ('worker1', 'worker'), ('worker2', 'worker')]:
        tokens[name] = {'Authorization': 'Bearer ' + app.state.database.issue_token(name, role)}
    client = TestClient(app)
    assert client.post('/v1/cases', json=CASE, headers=tokens['admin']).status_code == 201
    return client, tokens, app.state.database, verified


def submit(client, tokens, user='alice', key='answer-001'):
    response = client.post('/v1/submissions', json={'case_id': 'day1', 'answer': ' My original idea.\n'},
                           headers={**tokens[user], 'Idempotency-Key': key})
    assert response.status_code == 201, response.text
    return response.json()['id']


def run(client, tokens, submission_id, user='alice', key='command-001'):
    return client.post(f'/v1/submissions/{submission_id}/run',
                       headers={**tokens[user], 'Idempotency-Key': key})


def generated_build(client, tokens):
    submission_id = submit(client, tokens)
    assert run(client, tokens, submission_id).status_code == 202
    job = client.post('/v1/worker/claim', headers=tokens['worker1']).json()['job']
    response = client.post(f'/v1/worker/jobs/{job["id"]}/complete', headers=tokens['worker1'],
                           json={'lease_token': job['lease_token'], 'outcome': 'succeeded',
                                 'source_commit': 'c' * 40, 'summary': 'Implemented the participant idea.'})
    assert response.status_code == 200, response.text
    return response.json()['build']


def test_save_does_not_run_agent_and_answer_is_preserved(setup):
    client, tokens, db, _ = setup
    submission_id = submit(client, tokens)
    assert client.post('/v1/worker/claim', headers=tokens['worker1']).json() == {'job': None}
    detail = client.get('/v1/submissions/' + submission_id, headers=tokens['alice']).json()
    assert detail['answer'] == ' My original idea.\n'
    assert detail['jobs'] == []
    with db.connect() as c:
        assert c.execute('SELECT count(*) FROM jobs').fetchone()[0] == 0


def test_participant_isolation_and_roles(setup):
    client, tokens, _, _ = setup
    submission_id = submit(client, tokens)
    assert client.get('/v1/submissions/' + submission_id, headers=tokens['bob']).status_code == 404
    assert run(client, tokens, submission_id, user='bob').status_code == 404
    assert run(client, tokens, submission_id, user='admin').status_code == 403
    assert client.get('/v1/submissions', headers=tokens['bob']).json() == []
    assert client.post('/v1/cases', json=CASE, headers=tokens['alice']).status_code == 403
    assert client.post('/v1/worker/claim', headers=tokens['alice']).status_code == 403
    assert client.get('/v1/cases').status_code == 401


def test_idempotency_and_single_active_job_under_concurrency(setup):
    client, tokens, db, _ = setup
    submission_id = submit(client, tokens)
    assert submit(client, tokens) == submission_id
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda i: run(client, tokens, submission_id, key=f'command-{i:03}'), range(4)))
    assert all(r.status_code == 202 for r in responses)
    assert len({r.json()['id'] for r in responses}) == 1
    with ThreadPoolExecutor(max_workers=2) as pool:
        claimed = list(pool.map(lambda u: client.post('/v1/worker/claim', headers=tokens[u]).json()['job'], ['worker1', 'worker2']))
    assert sum(job is not None for job in claimed) == 1
    with db.connect() as c:
        assert c.execute('SELECT count(*) FROM jobs').fetchone()[0] == 1


def test_stale_lease_cannot_publish_and_is_not_automatically_retried(setup):
    client, tokens, db, _ = setup
    submission_id = submit(client, tokens)
    run(client, tokens, submission_id)
    job = client.post('/v1/worker/claim', headers=tokens['worker1']).json()['job']
    with db.connect(write=True) as c:
        c.execute('UPDATE jobs SET lease_until=? WHERE id=?', (time.time() - 1, job['id']))
    assert client.post('/v1/worker/claim', headers=tokens['worker2']).json()['job'] is None
    stale = client.post(f'/v1/worker/jobs/{job["id"]}/complete', headers=tokens['worker1'],
                        json={'lease_token': job['lease_token'], 'outcome': 'succeeded',
                              'source_commit': 'c' * 40, 'summary': 'Late result'})
    assert stale.status_code == 409
    retry = run(client, tokens, submission_id, key='command-retry')
    assert retry.status_code == 202 and retry.json()['id'] != job['id']


def test_verified_upload_and_installer_digest_gate(setup, tmp_path):
    client, tokens, db, verified = setup
    build = generated_build(client, tokens)
    assert build['bundle_id'].endswith('.b' + build['id'])
    assert client.get('/v1/builds/' + build['id'], headers=tokens['bob']).status_code == 404
    url = '/v1/builds/' + build['id'] + '/artifact'
    assert client.get(url, headers=tokens['worker1']).status_code == 409
    artifact = make_archive(tmp_path / 'build.zip', build['bundle_id'])
    headers = {**tokens['worker1'], 'Content-Type': 'application/zip'}
    response = client.post(url, content=artifact.read_bytes(), headers=headers)
    assert response.status_code == 200, response.text
    assert verified[0]['commit'] == 'c' * 40
    assert verified[0]['repo'] == CASE['source_repo']
    assert client.get(url, headers=tokens['worker1']).content == artifact.read_bytes()
    assert client.get(url, headers=tokens['alice']).status_code == 403
    assert client.post(url, content=artifact.read_bytes(), headers=headers).status_code == 409
    digest = response.json()['report']['sha256']
    stored = db.directory / 'artifacts' / (digest + '.zip')
    stored.chmod(0o600)
    stored.write_bytes(b'changed after verification')
    assert client.get(url, headers=tokens['worker1']).status_code == 409


def test_unsigned_upload_is_rejected_and_removed(tmp_path):
    def reject(*a, **kw):
        raise ArtifactError('Artifact provenance verification failed')
    app = create_app(Settings(tmp_path, 'crew/infra/.github/workflows/build.yml', 'b' * 40), reject)
    client = TestClient(app)
    tokens = {name: {'Authorization': 'Bearer ' + app.state.database.issue_token(name, role)}
              for name, role in [('admin', 'admin'), ('alice', 'participant'), ('worker1', 'worker')]}
    client.post('/v1/cases', json=CASE, headers=tokens['admin'])
    build = generated_build(client, tokens)
    archive = make_archive(tmp_path / 'unsigned.zip', build['bundle_id'])
    response = client.post('/v1/builds/' + build['id'] + '/artifact', content=archive.read_bytes(),
                           headers={**tokens['worker1'], 'Content-Type': 'application/zip'})
    assert response.status_code == 422
    assert list((tmp_path / 'quarantine').iterdir()) == []
    assert list((tmp_path / 'artifacts').iterdir()) == []


def test_revoked_token_stops_working(setup):
    client, tokens, db, _ = setup
    with db.connect(write=True) as c:
        c.execute("UPDATE principals SET disabled=1 WHERE id='alice'")
    assert client.get('/v1/cases', headers=tokens['alice']).status_code == 401


def test_json_body_limit(setup):
    client, tokens, _, _ = setup
    response = client.post('/v1/submissions', content=b' ' * 100_000,
                           headers={**tokens['alice'], 'Content-Type': 'application/json'})
    assert response.status_code == 413


def test_case_close_does_not_change_baseline_or_saved_answer(setup):
    client, tokens, _, _ = setup
    submission_id = submit(client, tokens)
    response = client.patch('/v1/cases/day1', json={'is_open': False}, headers=tokens['admin'])
    assert response.status_code == 200
    assert run(client, tokens, submission_id).status_code == 409
    assert client.get('/v1/submissions/' + submission_id, headers=tokens['alice']).status_code == 200
    assert client.patch('/v1/cases/day1', json={'base_commit': 'd' * 40}, headers=tokens['admin']).status_code == 422


def test_worker_can_recover_completion_response(setup):
    client, tokens, _, _ = setup
    build = generated_build(client, tokens)
    result = client.get('/v1/worker/jobs/' + build['job_id'], headers=tokens['worker1'])
    assert result.status_code == 200
    assert result.json()['build']['id'] == build['id']
    assert client.get('/v1/worker/jobs/' + build['job_id'], headers=tokens['worker2']).status_code == 404
