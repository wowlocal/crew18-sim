from contextlib import contextmanager
from pathlib import Path
import hashlib
import secrets
import sqlite3
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS principals (
 id TEXT PRIMARY KEY, role TEXT NOT NULL CHECK(role IN ('admin','participant','worker')),
 token_hash TEXT NOT NULL UNIQUE, disabled INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS cases (
 id TEXT PRIMARY KEY, day INTEGER NOT NULL CHECK(day BETWEEN 1 AND 7),
 title TEXT NOT NULL, prompt TEXT NOT NULL, source_repo TEXT NOT NULL,
 base_commit TEXT NOT NULL, project TEXT NOT NULL, scheme TEXT NOT NULL,
 runtime_version TEXT NOT NULL, is_open INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS submissions (
 id TEXT PRIMARY KEY, case_id TEXT NOT NULL REFERENCES cases(id),
 participant_id TEXT NOT NULL REFERENCES principals(id), answer TEXT NOT NULL,
 request_key TEXT NOT NULL, created_at REAL NOT NULL,
 UNIQUE(participant_id,request_key)
);
CREATE TABLE IF NOT EXISTS jobs (
 id TEXT PRIMARY KEY, submission_id TEXT NOT NULL REFERENCES submissions(id),
 requested_by TEXT NOT NULL REFERENCES principals(id), request_key TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','failed')),
 worker_id TEXT REFERENCES principals(id), lease_token TEXT, lease_until REAL,
 source_commit TEXT, summary TEXT, created_at REAL NOT NULL, finished_at REAL,
 UNIQUE(submission_id,request_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_job ON jobs(submission_id)
 WHERE state IN ('queued','running');
CREATE TABLE IF NOT EXISTS builds (
 id TEXT PRIMARY KEY, job_id TEXT NOT NULL UNIQUE REFERENCES jobs(id),
 bundle_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL DEFAULT 'awaiting_artifact'
 CHECK(state IN ('awaiting_artifact','verifying','rejected','verified')),
 artifact_sha256 TEXT, report_json TEXT, created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS audit (
 id INTEGER PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL,
 subject TEXT NOT NULL, created_at REAL NOT NULL
);
PRAGMA user_version = 1;
"""


def digest_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class Database:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / 'control.sqlite3'
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            version = db.execute('PRAGMA user_version').fetchone()[0]
            if version not in (0, 1):
                raise RuntimeError('Unsupported database schema version')
            db.executescript(SCHEMA)
        self.path.chmod(0o600)

    @contextmanager
    def connect(self, *, write=False):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            if write:
                db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def issue_token(self, principal_id: str, role: str) -> str:
        token = secrets.token_urlsafe(32)
        with self.connect(write=True) as db:
            db.execute('INSERT INTO principals(id,role,token_hash) VALUES(?,?,?)',
                       (principal_id, role, digest_token(token)))
            audit(db, 'local-cli', 'principal.created', principal_id)
        return token


def audit(db, actor, action, subject):
    db.execute('INSERT INTO audit(actor,action,subject,created_at) VALUES(?,?,?,?)',
               (actor, action, subject, time.time()))
