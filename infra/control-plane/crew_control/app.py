from dataclasses import dataclass
from pathlib import Path
import hmac
import json
import os
import re
import secrets
import tempfile
import time
import uuid

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.concurrency import run_in_threadpool

from .artifacts import ArtifactError, Limits, inspect_archive, sha256_file, verify_provenance
from .db import Database, audit, digest_token
from .models import CaseAvailability, CaseInput, CompletionInput, LeaseInput, SubmissionInput


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    signer_workflow: str = ''
    signer_digest: str = ''
    lease_seconds: int = 300

    @classmethod
    def environment(cls):
        return cls(Path(os.getenv('CREW_DATA_DIR', 'var/control')),
                   os.getenv('CREW_SIGNER_WORKFLOW', ''), os.getenv('CREW_SIGNER_DIGEST', ''))


class BodyLimit:
    """Bound both Content-Length and chunked bodies before JSON parsing or disk writes."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        maximum = Limits().compressed if scope['path'].endswith('/artifact') else 64 * 1024
        count = 0
        async def limited_receive():
            nonlocal count
            message = await receive()
            count += len(message.get('body', b''))
            if count > maximum:
                raise HTTPException(413, 'Request body exceeds limit')
            return message
        await self.app(scope, limited_receive, send)


def create_app(settings: Settings | None = None, provenance_verifier=verify_provenance):
    settings = settings or Settings.environment()
    database = Database(settings.data_dir)
    application = FastAPI(title='Crew 18 infrastructure API', version='0.1.0', redoc_url=None)
    application.add_middleware(BodyLimit)
    application.state.database = database
    auth_scheme = HTTPBearer(auto_error=False)
    for directory in ('quarantine', 'artifacts'):
        (settings.data_dir / directory).mkdir(mode=0o700, exist_ok=True)

    def principal(credentials: HTTPAuthorizationCredentials | None = Depends(auth_scheme)):
        if credentials is None or credentials.scheme.lower() != 'bearer':
            raise HTTPException(401, 'Bearer token required')
        with database.connect() as db:
            row = db.execute('SELECT id,role FROM principals WHERE token_hash=? AND disabled=0',
                             (digest_token(credentials.credentials),)).fetchone()
        if row is None:
            raise HTTPException(401, 'Invalid or revoked token')
        return dict(row)

    def role(user, *allowed):
        if user['role'] not in allowed:
            raise HTTPException(403, 'Role does not permit this operation')

    def request_key(value):
        if not value or not re.fullmatch(r'[A-Za-z0-9_-]{8,100}', value):
            raise HTTPException(400, 'Idempotency-Key must contain 8–100 letters, digits, _ or -')
        return value

    def owned_submission(db, submission_id, user):
        row = db.execute('SELECT * FROM submissions WHERE id=?', (submission_id,)).fetchone()
        if row is None or (user['role'] == 'participant' and row['participant_id'] != user['id']):
            raise HTTPException(404, 'Submission not found')
        return row

    def expire_jobs(db):
        now = time.time()
        expired = db.execute("SELECT id FROM jobs WHERE state='running' AND lease_until<?", (now,)).fetchall()
        for row in expired:
            db.execute("UPDATE jobs SET state='failed',summary=?,finished_at=?,lease_token=NULL WHERE id=?",
                       ('Worker lease expired; outcome unknown. Check its branch before retrying.', now, row['id']))
            audit(db, 'system', 'job.lease_expired', row['id'])

    def require_lease(db, job_id, user, token):
        row = db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
        if (row is None or row['state'] != 'running' or row['worker_id'] != user['id']
                or row['lease_until'] <= time.time() or not hmac.compare_digest(row['lease_token'] or '', token)):
            raise HTTPException(409, 'Job lease is stale or belongs to another worker')
        return row

    def job_plan(db, job_id):
        row = db.execute('''SELECT j.*,s.case_id,s.participant_id,s.answer,
          c.prompt,c.source_repo,c.base_commit,c.project,c.scheme,c.runtime_version
          FROM jobs j JOIN submissions s ON s.id=j.submission_id
          JOIN cases c ON c.id=s.case_id WHERE j.id=?''', (job_id,)).fetchone()
        result = dict(row)
        result['branch'] = f"crew18/{row['case_id']}/{row['submission_id']}/{row['id']}"
        return result

    def build_plan(db, build_id, user):
        build = db.execute('SELECT * FROM builds WHERE id=?', (build_id,)).fetchone()
        if build is None:
            raise HTTPException(404, 'Build not found')
        job = job_plan(db, build['job_id'])
        owned_submission(db, job['submission_id'], user)
        return {**dict(build), 'source_repo': job['source_repo'], 'source_commit': job['source_commit'],
                'source_branch': job['branch'], 'project': job['project'], 'scheme': job['scheme'],
                'runtime_version': job['runtime_version'], 'case_id': job['case_id'],
                'submission_id': job['submission_id'], 'participant_id': job['participant_id']}

    @application.get('/healthz')
    def health():
        with database.connect() as db:
            db.execute('SELECT 1')
        return {'status': 'ok', 'version': '0.1.0'}

    @application.post('/v1/cases', status_code=201)
    def add_case(body: CaseInput, user=Depends(principal)):
        role(user, 'admin')
        with database.connect(write=True) as db:
            if db.execute('SELECT id FROM cases WHERE id=?', (body.id,)).fetchone():
                raise HTTPException(409, 'Case already exists; baselines are immutable')
            values = body.model_dump()
            db.execute(f'INSERT INTO cases({",".join(values)}) VALUES({",".join("?" for _ in values)})',
                       tuple(values.values()))
            audit(db, user['id'], 'case.created', body.id)
        return values

    @application.patch('/v1/cases/{case_id}')
    def availability(case_id: str, body: CaseAvailability, user=Depends(principal)):
        role(user, 'admin')
        with database.connect(write=True) as db:
            result = db.execute('UPDATE cases SET is_open=? WHERE id=?', (body.is_open, case_id))
            if not result.rowcount:
                raise HTTPException(404, 'Case not found')
            audit(db, user['id'], 'case.opened' if body.is_open else 'case.closed', case_id)
        return {'id': case_id, 'is_open': body.is_open}

    @application.get('/v1/cases')
    def list_cases(user=Depends(principal)):
        with database.connect() as db:
            query = 'SELECT * FROM cases' + ('' if user['role'] == 'admin' else ' WHERE is_open=1')
            return [dict(row) for row in db.execute(query + ' ORDER BY day,id')]

    @application.post('/v1/submissions', status_code=201)
    def submit(body: SubmissionInput, idempotency_key: str | None = Header(None), user=Depends(principal)):
        role(user, 'participant')
        key = request_key(idempotency_key)
        with database.connect(write=True) as db:
            old = db.execute('SELECT * FROM submissions WHERE participant_id=? AND request_key=?',
                             (user['id'], key)).fetchone()
            if old:
                if old['answer'] != body.answer or old['case_id'] != body.case_id:
                    raise HTTPException(409, 'Idempotency key was used for a different answer')
                return dict(old)
            if not db.execute('SELECT id FROM cases WHERE id=? AND is_open=1', (body.case_id,)).fetchone():
                raise HTTPException(404, 'Open case not found')
            submission_id = uuid.uuid4().hex
            db.execute('INSERT INTO submissions VALUES(?,?,?,?,?,?)',
                       (submission_id, body.case_id, user['id'], body.answer, key, time.time()))
            audit(db, user['id'], 'submission.saved', submission_id)
            return dict(db.execute('SELECT * FROM submissions WHERE id=?', (submission_id,)).fetchone())

    @application.get('/v1/submissions')
    def list_submissions(limit: int = Query(100, ge=1, le=200), offset: int = Query(0, ge=0),
                         case_id: str | None = None, user=Depends(principal)):
        role(user, 'admin', 'participant')
        conditions, values = [], []
        if user['role'] == 'participant':
            conditions.append('participant_id=?')
            values.append(user['id'])
        if case_id is not None:
            conditions.append('case_id=?')
            values.append(case_id)
        query = 'SELECT * FROM submissions' + (' WHERE ' + ' AND '.join(conditions) if conditions else '')
        with database.connect() as db:
            rows = db.execute(query + ' ORDER BY created_at DESC,id LIMIT ? OFFSET ?', (*values, limit, offset))
            return [dict(row) for row in rows]

    @application.get('/v1/submissions/{submission_id}')
    def get_submission(submission_id: str, user=Depends(principal)):
        role(user, 'admin', 'participant')
        with database.connect() as db:
            submission = dict(owned_submission(db, submission_id, user))
            submission['jobs'] = [dict(row) for row in db.execute('''
                SELECT id,state,source_commit,summary,created_at,finished_at FROM jobs
                WHERE submission_id=? ORDER BY created_at''', (submission_id,))]
            submission['builds'] = [dict(row) for row in db.execute('''
                SELECT b.id,b.bundle_id,b.state,b.artifact_sha256,b.report_json FROM builds b
                JOIN jobs j ON j.id=b.job_id WHERE j.submission_id=?''', (submission_id,))]
            return submission

    @application.post('/v1/submissions/{submission_id}/run', status_code=202)
    def run_agent(submission_id: str, idempotency_key: str | None = Header(None), user=Depends(principal)):
        role(user, 'participant')
        key = request_key(idempotency_key)
        with database.connect(write=True) as db:
            submission = owned_submission(db, submission_id, user)
            expire_jobs(db)
            if not db.execute('SELECT id FROM cases WHERE id=? AND is_open=1', (submission['case_id'],)).fetchone():
                raise HTTPException(409, 'Case is closed')
            old = db.execute('SELECT id,state FROM jobs WHERE submission_id=? AND request_key=?',
                             (submission_id, key)).fetchone()
            if old:
                return dict(old)
            active = db.execute("SELECT id,state FROM jobs WHERE submission_id=? AND state IN ('queued','running')",
                                (submission_id,)).fetchone()
            if active:
                return dict(active)
            # Bound one participant's queue; this does not limit how many answers they can save.
            count = db.execute("SELECT count(*) FROM jobs WHERE requested_by=? AND state IN ('queued','running')",
                               (user['id'],)).fetchone()[0]
            if count >= 2:
                raise HTTPException(429, 'At most two active jobs per participant')
            job_id = uuid.uuid4().hex
            db.execute('INSERT INTO jobs(id,submission_id,requested_by,request_key,state,created_at) VALUES(?,?,?,?,?,?)',
                       (job_id, submission_id, user['id'], key, 'queued', time.time()))
            audit(db, user['id'], 'agent.requested', job_id)
            return {'id': job_id, 'state': 'queued'}

    @application.post('/v1/worker/claim')
    def claim(user=Depends(principal)):
        role(user, 'worker')
        with database.connect(write=True) as db:
            expire_jobs(db)
            if db.execute("SELECT id FROM jobs WHERE worker_id=? AND state='running'", (user['id'],)).fetchone():
                raise HTTPException(409, 'This worker already holds a job')
            row = db.execute("SELECT id FROM jobs WHERE state='queued' ORDER BY created_at,id LIMIT 1").fetchone()
            if row is None:
                return {'job': None}
            db.execute("UPDATE jobs SET state='running',worker_id=?,lease_token=?,lease_until=? WHERE id=?",
                       (user['id'], secrets.token_urlsafe(32), time.time() + settings.lease_seconds, row['id']))
            audit(db, user['id'], 'job.claimed', row['id'])
            return {'job': job_plan(db, row['id'])}

    @application.get('/v1/worker/jobs/{job_id}')
    def worker_status(job_id: str, user=Depends(principal)):
        role(user, 'worker')
        with database.connect() as db:
            row = db.execute('SELECT worker_id FROM jobs WHERE id=?', (job_id,)).fetchone()
            if row is None or row['worker_id'] != user['id']:
                raise HTTPException(404, 'Assigned job not found')
            plan = job_plan(db, job_id)
            build = db.execute('SELECT id FROM builds WHERE job_id=?', (job_id,)).fetchone()
            return {'job': plan, 'build': build_plan(db, build['id'], user) if build else None}

    @application.post('/v1/worker/jobs/{job_id}/heartbeat')
    def heartbeat(job_id: str, body: LeaseInput, user=Depends(principal)):
        role(user, 'worker')
        with database.connect(write=True) as db:
            require_lease(db, job_id, user, body.lease_token)
            deadline = time.time() + settings.lease_seconds
            db.execute('UPDATE jobs SET lease_until=? WHERE id=?', (deadline, job_id))
            return {'lease_until': deadline}

    @application.post('/v1/worker/jobs/{job_id}/complete')
    def complete(job_id: str, body: CompletionInput, user=Depends(principal)):
        role(user, 'worker')
        if body.outcome == 'succeeded' and body.source_commit is None:
            raise HTTPException(422, 'Successful generation requires an exact source commit')
        with database.connect(write=True) as db:
            require_lease(db, job_id, user, body.lease_token)
            db.execute('UPDATE jobs SET state=?,source_commit=?,summary=?,finished_at=?,lease_token=NULL WHERE id=?',
                       (body.outcome, body.source_commit, body.summary, time.time(), job_id))
            audit(db, user['id'], 'job.' + body.outcome, job_id)
            if body.outcome == 'failed':
                return {'build': None}
            build_id = uuid.uuid4().hex
            plan = job_plan(db, job_id)
            bundle = f"io.podlodka.crew18.s{plan['submission_id']}.b{build_id}"
            db.execute('INSERT INTO builds(id,job_id,bundle_id,created_at) VALUES(?,?,?,?)',
                       (build_id, job_id, bundle, time.time()))
            return {'build': build_plan(db, build_id, user)}

    @application.get('/v1/builds/{build_id}')
    def get_build(build_id: str, user=Depends(principal)):
        with database.connect() as db:
            return build_plan(db, build_id, user)

    @application.post('/v1/builds/{build_id}/artifact')
    async def upload(build_id: str, request: Request, user=Depends(principal)):
        role(user, 'worker', 'admin')
        if request.headers.get('content-type') != 'application/zip':
            raise HTTPException(415, 'Send the ZIP body with Content-Type: application/zip')
        if not settings.signer_workflow or not settings.signer_digest:
            raise HTTPException(503, 'Trusted artifact signer is not configured')
        with database.connect(write=True) as db:
            plan = build_plan(db, build_id, user)
            if plan['state'] not in ('awaiting_artifact', 'rejected'):
                raise HTTPException(409, 'Build already uploaded or verification in progress')
            db.execute("UPDATE builds SET state='verifying' WHERE id=?", (build_id,))
        descriptor, name = tempfile.mkstemp(prefix='upload-', suffix='.zip', dir=settings.data_dir / 'quarantine')
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                size = 0
                async for block in request.stream():
                    size += len(block)
                    if size > Limits().compressed:
                        raise HTTPException(413, 'Archive exceeds upload limit')
                    output.write(block)
            report = await run_in_threadpool(inspect_archive, temporary, plan['bundle_id'], plan['runtime_version'])
            report['provenance'] = await run_in_threadpool(
                provenance_verifier, temporary, repo=plan['source_repo'], commit=plan['source_commit'],
                signer_workflow=settings.signer_workflow, signer_digest=settings.signer_digest)
            target = settings.data_dir / 'artifacts' / (report['sha256'] + '.zip')
            try:
                os.link(temporary, target)  # Publish without overwriting an existing content-addressed object.
                target.chmod(0o400)
            except FileExistsError:
                if sha256_file(target) != report['sha256']:
                    raise ArtifactError('Stored artifact digest mismatch')
            with database.connect(write=True) as db:
                db.execute("UPDATE builds SET state='verified',artifact_sha256=?,report_json=? WHERE id=?",
                           (report['sha256'], json.dumps(report), build_id))
                audit(db, user['id'], 'artifact.verified', build_id)
            return {'state': 'verified', 'report': report}
        except BaseException as exc:
            with database.connect(write=True) as db:
                public_error = str(exc) if isinstance(exc, ArtifactError) else 'Upload or verification interrupted'
                db.execute("UPDATE builds SET state='rejected',report_json=? WHERE id=?",
                           (json.dumps({'error': public_error}), build_id))
                audit(db, user['id'], 'artifact.rejected', build_id)
            if isinstance(exc, ArtifactError):
                raise HTTPException(422, str(exc)) from exc
            raise
        finally:
            temporary.unlink(missing_ok=True)

    @application.get('/v1/builds/{build_id}/artifact')
    def download(build_id: str, user=Depends(principal)):
        role(user, 'admin', 'worker')
        with database.connect() as db:
            plan = build_plan(db, build_id, user)
        if plan['state'] != 'verified':
            raise HTTPException(409, 'Only verified builds can be downloaded for installation')
        artifact = settings.data_dir / 'artifacts' / (plan['artifact_sha256'] + '.zip')
        if not artifact.is_file() or sha256_file(artifact) != plan['artifact_sha256']:
            raise HTTPException(409, 'Stored artifact integrity check failed')
        return FileResponse(artifact, media_type='application/zip', filename=f'{build_id}.app.zip',
                            headers={'X-Artifact-SHA256': plan['artifact_sha256']})

    return application
