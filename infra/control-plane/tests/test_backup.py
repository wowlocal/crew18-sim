import sqlite3
import tarfile
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
