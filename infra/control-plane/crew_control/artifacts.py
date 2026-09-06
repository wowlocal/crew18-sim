"""Bounded, non-executing validation. An archive is never extracted by this module."""
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import hashlib
import plistlib
import re
import stat
import struct
import subprocess
import unicodedata
import zipfile
import zlib

MIB = 1024 * 1024
ARM64 = 0x0100000C
THIN = {b'\xcf\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xcf': '>',
        b'\xce\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xce': '>'}
FAT = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
       b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}


class ArtifactError(ValueError):
    pass


@dataclass(frozen=True)
class Limits:
    compressed: int = 128 * MIB
    unpacked: int = 512 * MIB
    files: int = 20_000
    binary: int = 64 * MIB
    ratio: int = 200


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(MIB), b''):
            h.update(block)
    return h.hexdigest()


def version(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r'\d{1,2}(\.\d{1,2}){1,2}', value):
        raise ArtifactError('Invalid OS version')
    parts = [int(p) for p in value.split('.')]
    return tuple((parts + [0, 0])[:3])


def macho_slices(data: bytes) -> list[dict]:
    magic = data[:4]
    if magic in FAT:
        endian, wide = FAT[magic]
        if len(data) < 8:
            raise ArtifactError('Truncated fat Mach-O')
        count = struct.unpack_from(endian + 'I', data, 4)[0]
        stride = 32 if wide else 20
        if not 1 <= count <= 16 or 8 + count * stride > len(data):
            raise ArtifactError('Invalid fat Mach-O table')
        result, regions = [], []
        for i in range(count):
            start = 8 + i * stride
            cpu = struct.unpack_from(endian + 'I', data, start)[0]
            offset, size = struct.unpack_from(endian + ('QQ' if wide else 'II'), data, start + 8)
            if offset < 8 + count * stride or size < 28 or offset + size > len(data):
                raise ArtifactError('Invalid Mach-O slice bounds')
            if any(offset < b and offset + size > a for a, b in regions):
                raise ArtifactError('Overlapping Mach-O slices')
            regions.append((offset, offset + size))
            if data[offset:offset + 4] not in THIN:
                raise ArtifactError('Invalid nested Mach-O slice')
            child = macho_slices(data[offset:offset + size])
            if len(child) != 1 or child[0]['cpu'] != cpu:
                raise ArtifactError('Mach-O architecture table mismatch')
            result.extend(child)
        return result
    if magic not in THIN:
        raise ArtifactError('Executable is not Mach-O')
    endian = THIN[magic]
    header_size = 32 if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf') else 28
    if len(data) < header_size:
        raise ArtifactError('Truncated Mach-O header')
    _, cpu, _, filetype, ncmds, sizeofcmds, _ = struct.unpack_from(endian + '7I', data)
    if ncmds > 4096 or header_size + sizeofcmds > len(data):
        raise ArtifactError('Invalid Mach-O commands')
    cursor, platforms = header_size, []
    for _ in range(ncmds):
        if cursor + 8 > header_size + sizeofcmds:
            raise ArtifactError('Truncated Mach-O command')
        cmd, size = struct.unpack_from(endian + 'II', data, cursor)
        if size < 8 or size % 4 or cursor + size > header_size + sizeofcmds:
            raise ArtifactError('Invalid Mach-O command size')
        if cmd == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ArtifactError('Truncated LC_BUILD_VERSION')
            platform, minos = struct.unpack_from(endian + 'II', data, cursor + 8)
            platforms.append((platform, (minos >> 16, (minos >> 8) & 255, minos & 255)))
        cursor += size
    if cursor != header_size + sizeofcmds:
        raise ArtifactError('Mach-O load command length mismatch')
    return [{'cpu': cpu, 'filetype': filetype, 'platforms': platforms}]


def check_extra(extra: bytes):
    # Do not let another ZIP implementation substitute names from Unicode-path
    # or platform-specific override records that Python does not interpret.
    while extra:
        if len(extra) < 4:
            raise ArtifactError('Malformed ZIP extra field')
        kind, length = struct.unpack_from('<HH', extra)
        if length + 4 > len(extra) or kind not in {0x0001, 0x000A, 0x5455, 0x5855, 0x7875}:
            raise ArtifactError('Unsupported ZIP extra field')
        extra = extra[4 + length:]


def check_compressed_stream(path: Path, entry):
    # ZipExtFile truncates decompressed data to the advertised file_size. Verify
    # the raw stream independently so a forged size/CRC cannot conceal a ZIP bomb.
    with path.open('rb') as raw:
        raw.seek(entry.header_offset)
        header = raw.read(30)
        if len(header) != 30:
            raise ArtifactError('Truncated ZIP local header')
        signature, _, flags, method, _, _, _, _, _, name_size, extra_size = struct.unpack('<4s5H3I2H', header)
        if signature != b'PK\x03\x04' or flags != entry.flag_bits or method != entry.compress_type:
            raise ArtifactError('ZIP headers disagree')
        raw_name = raw.read(name_size)
        try:
            name = raw_name.decode('utf-8' if flags & 0x800 else 'cp437')
        except UnicodeDecodeError as exc:
            raise ArtifactError('Invalid ZIP filename encoding') from exc
        if name != entry.orig_filename:
            raise ArtifactError('ZIP filenames disagree')
        check_extra(raw.read(extra_size))
        remaining, count, crc = entry.compress_size, 0, 0
        decoder = zlib.decompressobj(-15) if method == zipfile.ZIP_DEFLATED else None
        while remaining:
            block = raw.read(min(64 * 1024, remaining))
            if not block:
                raise ArtifactError('Truncated ZIP compressed data')
            remaining -= len(block)
            pending = block
            while pending:
                if decoder is None:
                    output, pending = pending, b''
                else:
                    output = decoder.decompress(pending, min(MIB, entry.file_size + 1 - count))
                    pending = decoder.unconsumed_tail
                    if decoder.unused_data:
                        raise ArtifactError('Trailing bytes in ZIP compressed stream')
                count += len(output)
                if count > entry.file_size:
                    raise ArtifactError('Actual decompressed data exceeds declared ZIP size')
                crc = zlib.crc32(output, crc)
        if count != entry.file_size or crc != entry.CRC or (decoder is not None and not decoder.eof):
            raise ArtifactError('ZIP decompressed size or CRC mismatch')


def inspect_archive(path: Path, expected_bundle: str, runtime: str,
                    limits: Limits = Limits()) -> dict:
    path = Path(path)
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', expected_bundle):
        raise ArtifactError('Invalid expected bundle ID')
    runtime_tuple = version(runtime)
    if path.stat().st_size > limits.compressed:
        raise ArtifactError('Archive exceeds compressed size limit')
    try:
        return _inspect_zip(path, expected_bundle, runtime_tuple, limits)
    except (zipfile.BadZipFile, EOFError, struct.error, OverflowError, RuntimeError, zlib.error) as exc:
        raise ArtifactError('Corrupt or unsupported ZIP archive') from exc


def _inspect_zip(path, expected_bundle, runtime, limits):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not entries or len(entries) > limits.files:
            raise ArtifactError('Invalid archive entry count')
        seen, nodes, roots, binaries, plists, total = set(), {}, set(), {}, {}, 0
        for entry in entries:
            if entry.orig_filename != entry.filename:
                raise ArtifactError('Unsafe archive path')
            check_extra(entry.extra)
            name = entry.filename.rstrip('/')
            parts = name.split('/')
            if (not name or any(p in ('', '.', '..') for p in parts)
                    or '\\' in name or ':' in name or name.startswith('/')
                    or any(ord(c) < 32 or ord(c) == 127 for c in name)):
                raise ArtifactError('Unsafe archive path')
            folded = unicodedata.normalize('NFC', name).casefold()
            if folded in seen:
                raise ArtifactError('Duplicate or case-colliding archive path')
            seen.add(folded)
            # Record implicit parents too: APFS folds directory names even if the
            # ZIP contains no explicit directory entries. Reject files used as parents.
            for i in range(1, len(parts) + 1):
                component = '/'.join(parts[:i])
                key = unicodedata.normalize('NFC', component).casefold()
                node = (component, i < len(parts) or entry.is_dir())
                if key in nodes and nodes[key] != node:
                    raise ArtifactError('Conflicting archive directory or file')
                nodes[key] = node
            mode = entry.external_attr >> 16
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ArtifactError('Links and special files are not allowed')
            if entry.flag_bits & 1 or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise ArtifactError('Encrypted or unsupported ZIP entry')
            roots.add(parts[0])
            total += entry.file_size
            if total > limits.unpacked or entry.file_size > max(1, entry.compress_size) * limits.ratio:
                raise ArtifactError('Archive exceeds unpacked size or compression ratio limit')
            check_compressed_stream(path, entry)
            if entry.is_dir():
                if entry.file_size:
                    raise ArtifactError('Directory entry contains data')
                continue
            with archive.open(entry) as stream:
                first = stream.read(4)
                is_macho = first in THIN or first in FAT
                is_plist = name.endswith('/Info.plist')
                cap = limits.binary if is_macho else MIB if is_plist else limits.unpacked
                contents = bytearray(first) if is_macho or is_plist else None
                count = len(first)
                while block := stream.read(MIB):
                    count += len(block)
                    if count > cap or count > entry.file_size:
                        raise ArtifactError('Archive entry exceeds size limit')
                    if contents is not None:
                        contents.extend(block)
                if count != entry.file_size:
                    raise ArtifactError('Archive entry size mismatch')
                if is_macho:
                    slices = macho_slices(bytes(contents))
                    arm = [s for s in slices if s['cpu'] == ARM64]
                    if len(arm) != 1 or len(arm[0]['platforms']) != 1:
                        raise ArtifactError('Every Mach-O must contain one identifiable arm64 simulator slice')
                    platform, minos = arm[0]['platforms'][0]
                    if platform != 7:
                        raise ArtifactError('Mach-O platform must be IOSSIMULATOR, not iOS or macOS')
                    if minos > runtime:
                        raise ArtifactError('Binary requires a newer simulator runtime')
                    binaries[name] = arm[0]
                if is_plist:
                    try:
                        plist = plistlib.loads(contents)
                    except Exception as exc:
                        raise ArtifactError('Invalid Info.plist') from exc
                    if not isinstance(plist, dict):
                        raise ArtifactError('Info.plist must be a dictionary')
                    plists[name] = plist
        if len(roots) != 1 or not next(iter(roots)).endswith('.app'):
            raise ArtifactError('Archive must contain exactly one root .app and no other files')
        app = next(iter(roots))
        main = plists.get(f'{app}/Info.plist')
        if not main or main.get('CFBundleIdentifier') != expected_bundle:
            raise ArtifactError('Bundle ID does not match the server-issued build plan')
        if main.get('CFBundlePackageType') != 'APPL':
            raise ArtifactError('Root bundle must have package type APPL')
        if version(main.get('MinimumOSVersion', '')) > runtime:
            raise ArtifactError('App requires a newer simulator runtime')
        if main.get('CFBundleSupportedPlatforms') != ['iPhoneSimulator']:
            raise ArtifactError('Info.plist must target iPhoneSimulator')
        for location, plist in plists.items():
            bundle_dir = str(PurePosixPath(location).parent)
            if not bundle_dir.endswith(('.app', '.appex', '.framework')):
                continue
            executable = plist.get('CFBundleExecutable')
            if not isinstance(executable, str) or '/' in executable or executable in ('', '.', '..'):
                raise ArtifactError('Invalid CFBundleExecutable')
            binary_path = f'{bundle_dir}/{executable}'
            if binary_path not in binaries:
                raise ArtifactError('Bundle executable missing or not Mach-O')
            if bundle_dir.endswith('.appex') and not str(plist.get('CFBundleIdentifier', '')).startswith(expected_bundle + '.'):
                raise ArtifactError('Extension bundle ID must belong to the main application')
        if binaries[f'{app}/{main["CFBundleExecutable"]}']['filetype'] != 2:
            raise ArtifactError('Main binary is not an executable')
        return {'sha256': sha256_file(path), 'bundle_id': expected_bundle,
                'app_directory': app, 'minimum_os': main['MinimumOSVersion'],
                'files': len(entries), 'unpacked_bytes': total,
                'mach_o_files': len(binaries), 'platform': 'IOSSIMULATOR', 'architecture': 'arm64'}


def verify_provenance(path: Path, *, repo: str, commit: str,
                      signer_workflow: str, signer_digest: str) -> dict:
    if not signer_workflow or not re.fullmatch(r'[0-9a-f]{40}', signer_digest):
        raise ArtifactError('Trusted signer workflow and its pinned commit are not configured')
    command = ['gh', 'attestation', 'verify', str(path), '--repo', repo,
               '--source-digest', commit, '--signer-workflow', signer_workflow,
               '--signer-digest', signer_digest, '--deny-self-hosted-runners', '--format', 'json']
    try:
        result = subprocess.run(command, capture_output=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ArtifactError('Artifact attestation verifier unavailable') from exc
    if result.returncode != 0:
        raise ArtifactError('Artifact provenance verification failed')
    # gh enforces certificate identity, source commit, signer pin and artifact digest.
    # Do not store its full output (certificates and unnecessary workflow metadata).
    return {'provider': 'github-attestation', 'repo': repo, 'source_commit': commit,
            'signer_workflow': signer_workflow, 'signer_digest': signer_digest}
