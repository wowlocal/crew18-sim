import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import tarfile
import tempfile

import httpx

from .app import Settings, create_app
from .artifacts import inspect_archive, sha256_file
from .db import Database, audit


def private_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(data, output, indent=2)
        output.write('\n')


def read_token(path):
    value = Path(path).read_text().strip()
    if value.startswith('{'):
        return json.loads(value)['token']
    return value


def backup(database, output):
    # Snapshot the database first; all referenced verified artifacts are immutable.
    with tempfile.TemporaryDirectory(prefix='crew-backup-') as temporary:
        snapshot = Path(temporary) / 'control.sqlite3'
        with database.connect() as source:
            destination = sqlite3.connect(snapshot)
            source.backup(destination)
            destination.close()
        with sqlite3.connect(snapshot) as db:
            hashes = [r[0] for r in db.execute("SELECT DISTINCT artifact_sha256 FROM builds WHERE state='verified'")]
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as raw, tarfile.open(fileobj=raw, mode='w:gz') as archive:
            archive.add(snapshot, arcname='control.sqlite3')
            for digest in hashes:
                path = database.directory / 'artifacts' / f'{digest}.zip'
                if sha256_file(path) != digest:
                    raise ValueError('Refusing to back up a corrupt artifact')
                archive.add(path, arcname=f'artifacts/{digest}.zip')


def promote(args):
    from urllib.parse import urlparse
    for address in (args.api, args.tapflow):
        parsed = urlparse(address)
        if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1')):
            raise ValueError('Use HTTPS, or HTTP on loopback only')
    headers = {'Authorization': 'Bearer ' + read_token(args.token_file)}
    with httpx.Client(base_url=args.api, headers=headers, timeout=120, follow_redirects=False) as client:
        response = client.get(f'/v1/builds/{args.build_id}')
        response.raise_for_status()
        build = response.json()
        if build['state'] != 'verified':
            raise ValueError('Build has not passed verification')
        with tempfile.TemporaryDirectory(prefix='crew-promote-') as temporary:
            artifact = Path(temporary) / 'build.app.zip'
            with client.stream('GET', f'/v1/builds/{args.build_id}/artifact') as response:
                response.raise_for_status()
                count = 0
                with artifact.open('wb') as output:
                    for block in response.iter_bytes():
                        count += len(block)
                        if count > 128 * 1024 * 1024:
                            raise ValueError('Downloaded archive exceeds limit')
                        output.write(block)
            report = inspect_archive(artifact, build['bundle_id'], build['runtime_version'])
            if report['sha256'] != build['artifact_sha256']:
                raise ValueError('Downloaded artifact digest mismatch')
            # No code or archive mutation occurs between this check and import.
            label = f"{build['case_id']} / {build['participant_id']} / {build['source_commit'][:12]}"
            with artifact.open('rb') as data:
                result = httpx.post(args.tapflow.rstrip('/') + '/api/v1/builds',
                    headers={'Authorization': 'Bearer ' + read_token(args.tapflow_token_file)},
                    data={'platform': 'ios', 'label': label, 'status': 'Backlog'},
                    files={'file': ('build.app.zip', data, 'application/zip')}, timeout=120)
                result.raise_for_status()
            result = result.json()
            print(json.dumps({'tapflow_build_id': result.get('id'), 'artifact_sha256': report['sha256']}))


def main():
    parser = argparse.ArgumentParser(description='Crew 18 infrastructure controls')
    parser.add_argument('--data-dir', type=Path, default=Path(os.getenv('CREW_DATA_DIR', 'var/control')))
    sub = parser.add_subparsers(dest='command', required=True)
    user = sub.add_parser('create-user')
    user.add_argument('--id', required=True)
    user.add_argument('--role', choices=['admin', 'participant', 'worker'], required=True)
    user.add_argument('--token-file', type=Path, required=True)
    revoke = sub.add_parser('revoke-user')
    revoke.add_argument('--id', required=True)
    serve = sub.add_parser('serve')
    serve.add_argument('--host', default='127.0.0.1')
    serve.add_argument('--port', type=int, default=4100)
    inspect = sub.add_parser('inspect')
    inspect.add_argument('archive', type=Path)
    inspect.add_argument('--bundle-id', required=True)
    inspect.add_argument('--runtime', required=True)
    archive = sub.add_parser('backup')
    archive.add_argument('--output', type=Path, required=True)
    reset = sub.add_parser('recover-uploads', help='Run only while the API is stopped after an unclean shutdown')
    promote_cmd = sub.add_parser('promote', help='Import a verified archive into Tapflow; does not start it')
    for flag in ['api', 'build-id', 'token-file', 'tapflow', 'tapflow-token-file']:
        promote_cmd.add_argument('--' + flag, required=True)
    api_cmd = sub.add_parser('request', help='Call the API without putting a bearer token in shell arguments')
    api_cmd.add_argument('--api', default='http://127.0.0.1:4100')
    api_cmd.add_argument('--token-file', type=Path, required=True)
    api_cmd.add_argument('--method', choices=['GET','POST','PATCH'], default='GET')
    api_cmd.add_argument('--path', required=True)
    api_cmd.add_argument('--body-file', type=Path)
    api_cmd.add_argument('--key')
    args = parser.parse_args()
    if args.command == 'request':
        from urllib.parse import urlparse
        parsed = urlparse(args.api)
        if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('localhost','127.0.0.1','::1')):
            parser.error('Use HTTPS, or HTTP on loopback only')
        if not args.path.startswith('/v1/'):
            parser.error('Expected a /v1/ API path')
        headers = {'Authorization': 'Bearer ' + read_token(args.token_file)}
        if args.key:
            headers['Idempotency-Key'] = args.key
        body = json.loads(args.body_file.read_text()) if args.body_file else None
        response = httpx.request(args.method, args.api.rstrip('/') + args.path,
                                 headers=headers, json=body, timeout=30, follow_redirects=False)
        response.raise_for_status()
        print(json.dumps(response.json(), ensure_ascii=False, indent=2))
        return
    if args.command == 'inspect':
        print(json.dumps(inspect_archive(args.archive, args.bundle_id, args.runtime), indent=2))
        return
    if args.command == 'promote':
        promote(args)
        return
    if args.command == 'serve':
        import uvicorn
        os.environ['CREW_DATA_DIR'] = str(args.data_dir)
        uvicorn.run(create_app(Settings.environment()), host=args.host, port=args.port, proxy_headers=False)
        return
    if args.command == 'create-user':
        if not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', args.id):
            parser.error('User ID must be a lowercase slug, up to 32 characters')
        if args.token_file.exists():
            parser.error('Token output already exists; refusing to overwrite it')
        db = Database(args.data_dir)
        token = db.issue_token(args.id, args.role)
        private_json(args.token_file, {'id': args.id, 'role': args.role, 'token': token})
        print(f'User created. Token saved to {args.token_file}; keep it outside Git.')
    elif args.command == 'revoke-user':
        with Database(args.data_dir).connect(write=True) as db:
            db.execute('UPDATE principals SET disabled=1 WHERE id=?', (args.id,))
            audit(db, 'local-cli', 'principal.revoked', args.id)
        print('Token revoked.')
    elif args.command == 'backup':
        backup(Database(args.data_dir), args.output)
        print(f'Consistent database and verified artifacts saved to {args.output}')
    elif args.command == 'recover-uploads':
        database = Database(args.data_dir)
        with database.connect(write=True) as db:
            result = db.execute("UPDATE builds SET state='awaiting_artifact' WHERE state='verifying'")
            audit(db, 'local-cli', 'uploads.recovered', str(result.rowcount))
        for path in (args.data_dir / 'quarantine').glob('upload-*.zip'):
            path.unlink()
        print(f'Reset {result.rowcount} interrupted uploads.')


if __name__ == '__main__':
    main()
