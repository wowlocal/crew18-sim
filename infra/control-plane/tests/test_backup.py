import sqlite3
import tarfile
import hashlib

import pytest

from crew_control.cli import backup
from crew_control.db import Database


def test_backup_restores_database_without_raw_credentials(tmp_path):
    database = Database(tmp_path / 'data')
    token = database.issue_token('participant', 'participant')
    output = tmp_path / 'backup.tar.gz'
    backup(database, output)
    assert output.stat().st_mode & 0o077 == 0
    with tarfile.open(output) as archive:
        assert archive.getnames() == ['control.sqlite3']
        data = archive.extractfile('control.sqlite3').read()
    assert token.encode() not in data
    restored = tmp_path / 'restored.sqlite3'
    restored.write_bytes(data)
    with sqlite3.connect(restored) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert db.execute('SELECT id FROM principals').fetchone()[0] == 'participant'


@pytest.fixture
def verified_database(tmp_path):
    database = Database(tmp_path / 'data')
    database.issue_token('participant', 'participant')
    artifact = b'verified artifact contents'
    digest = hashlib.sha256(artifact).hexdigest()
    with database.connect(write=True) as db:
        db.execute('INSERT INTO cases VALUES(?,?,?,?,?,?,?,?,?,?)',
                   ('case', 1, 'Title', 'Prompt', 'crew/repo', 'a' * 40,
                    'App.xcodeproj', 'App', '26.5', 1))
        db.execute('INSERT INTO submissions VALUES(?,?,?,?,?,?)',
                   ('submission', 'case', 'participant', 'Answer', 'answer-key', 0))
        db.execute('''INSERT INTO jobs(id,submission_id,requested_by,request_key,state,created_at)
                      VALUES(?,?,?,?,?,?)''',
                   ('job', 'submission', 'participant', 'run-key', 'succeeded', 0))
        db.execute('''INSERT INTO builds(id,job_id,bundle_id,state,artifact_sha256,created_at)
                      VALUES(?,?,?,?,?,?)''',
                   ('build', 'job', 'io.test.prototype', 'verified', digest, 0))
    path = database.directory / 'artifacts' / f'{digest}.zip'
    path.parent.mkdir()
    path.write_bytes(artifact)
    return database, path, artifact


@pytest.mark.parametrize('failure', ['missing', 'corrupt', 'write'])
def test_failed_backup_leaves_no_output_and_can_be_retried(verified_database, tmp_path, monkeypatch, failure):
    database, artifact_path, contents = verified_database
    output = tmp_path / 'backup.tar.gz'
    if failure == 'missing':
        artifact_path.unlink()
    elif failure == 'corrupt':
        artifact_path.write_bytes(b'corrupted')

    original_add = tarfile.TarFile.add
    def fail_artifact_write(archive, name, *args, **kwargs):
        if name == artifact_path:
            raise OSError('Backup write failed')
        return original_add(archive, name, *args, **kwargs)

    with monkeypatch.context() as patch:
        if failure == 'write':
            patch.setattr(tarfile.TarFile, 'add', fail_artifact_write)
        with pytest.raises((OSError, ValueError)):
            backup(database, output)
    assert not output.exists(), 'A failed backup must not look like a completed backup'
    assert {path.name for path in tmp_path.iterdir()} == {'data'}

    artifact_path.write_bytes(contents)
    backup(database, output)
    assert output.stat().st_mode & 0o077 == 0
    with tarfile.open(output) as archive:
        assert archive.getnames() == ['control.sqlite3', f'artifacts/{artifact_path.name}']
        assert archive.extractfile(f'artifacts/{artifact_path.name}').read() == contents


def test_backup_never_overwrites_existing_output(verified_database, tmp_path):
    database, _, _ = verified_database
    output = tmp_path / 'backup.tar.gz'
    output.write_bytes(b'existing backup')
    with pytest.raises(FileExistsError):
        backup(database, output)
    assert output.read_bytes() == b'existing backup'
    assert {path.name for path in tmp_path.iterdir()} == {'data', 'backup.tar.gz'}
