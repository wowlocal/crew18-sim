from dataclasses import replace
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import zipfile

import pytest

from crew_control.artifacts import ArtifactError, Limits, inspect_archive, verify_provenance


def binary(platform=7, minos=17 << 16, filetype=2):
    return struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, filetype, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, minos, minos, 0)


def make_archive(path, bundle='io.test.prototype', *, platform=7, extra=None, executable='ActualExecutable'):
    info = {'CFBundleIdentifier': bundle, 'CFBundleExecutable': executable,
            'CFBundlePackageType': 'APPL', 'MinimumOSVersion': '17.0',
            'CFBundleSupportedPlatforms': ['iPhoneSimulator']}
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('Game.app/Info.plist', plistlib.dumps(info))
        z.writestr('Game.app/' + executable, binary(platform))
        for name, data in (extra or {}).items():
            z.writestr(name, data)
    return path


def test_checks_actual_executable_instead_of_app_directory_name(tmp_path):
    archive = make_archive(tmp_path / 'game.zip')
    report = inspect_archive(archive, 'io.test.prototype', '26.5')
    assert report['architecture'] == 'arm64'
    assert report['mach_o_files'] == 1
    assert len(report['sha256']) == 64


@pytest.mark.parametrize('platform', [1, 2, 6])
def test_rejects_arm64_mac_device_and_catalyst_binaries(tmp_path, platform):
    archive = make_archive(tmp_path / 'game.zip', platform=platform)
    with pytest.raises(ArtifactError, match='platform'):
        inspect_archive(archive, 'io.test.prototype', '26.5')


def test_rejects_wrong_identity_and_incompatible_runtime(tmp_path):
    archive = make_archive(tmp_path / 'game.zip')
    with pytest.raises(ArtifactError, match='Bundle ID'):
        inspect_archive(archive, 'io.someone.else', '26.5')
    with pytest.raises(ArtifactError, match='newer'):
        inspect_archive(archive, 'io.test.prototype', '16.0')


@pytest.mark.parametrize('name', ['../outside', '/etc/passwd', 'Game.app/../../escape',
                                 'Game.app/one\\two', 'Game.app/Info.PLIST',
                                 'Other.app/Info.plist', 'Game.app/file\nname'])
def test_rejects_unsafe_and_ambiguous_paths(tmp_path, name):
    archive = make_archive(tmp_path / 'game.zip', extra={name: b'x'})
    with pytest.raises(ArtifactError):
        inspect_archive(archive, 'io.test.prototype', '26.5')


def test_rejects_symlink(tmp_path):
    archive = make_archive(tmp_path / 'game.zip')
    with zipfile.ZipFile(archive, 'a') as z:
        entry = zipfile.ZipInfo('Game.app/link')
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        z.writestr(entry, '/Users')
    with pytest.raises(ArtifactError, match='Links'):
        inspect_archive(archive, 'io.test.prototype', '26.5')


def test_rejects_case_collisions_in_implicit_directories(tmp_path):
    archive = make_archive(tmp_path / 'game.zip', extra={
        'Game.app/Assets/one': b'a', 'Game.app/assets/two': b'b'})
    with pytest.raises(ArtifactError, match='directory'):
        inspect_archive(archive, 'io.test.prototype', '26.5')


def test_rejects_zip_bomb_and_bounds_file_count(tmp_path):
    archive = make_archive(tmp_path / 'game.zip', extra={'Game.app/bomb': b'0' * 1_000_000})
    with pytest.raises(ArtifactError, match='ratio'):
        inspect_archive(archive, 'io.test.prototype', '26.5')
    archive = make_archive(tmp_path / 'normal.zip')
    with pytest.raises(ArtifactError, match='entry count'):
        inspect_archive(archive, 'io.test.prototype', '26.5', replace(Limits(), files=1))


def test_checks_embedded_macho_even_outside_named_framework(tmp_path):
    archive = make_archive(tmp_path / 'game.zip', extra={'Game.app/hidden.dylib': binary(2, filetype=6)})
    with pytest.raises(ArtifactError, match='platform'):
        inspect_archive(archive, 'io.test.prototype', '26.5')


@pytest.mark.parametrize('bundle_dir', ['PlugIns/Widget.appex', 'PlugIns/Widget.APPEX',
                                       'Frameworks/Shared.framework', 'Nested.app'])
@pytest.mark.parametrize('plist_name', [None, 'info.plist', 'Info.PLIST'])
def test_embedded_bundles_cannot_skip_metadata_validation(tmp_path, bundle_dir, plist_name):
    extra = {f'Game.app/{bundle_dir}/Executable': binary()}
    if plist_name:
        extra[f'Game.app/{bundle_dir}/{plist_name}'] = plistlib.dumps({
            'CFBundleIdentifier': 'io.someone.else', 'CFBundleExecutable': 'Missing'})
    archive = make_archive(tmp_path / 'game.zip', extra=extra)
    with pytest.raises(ArtifactError, match='Info.plist'):
        inspect_archive(archive, 'io.test.prototype', '26.5')


@pytest.mark.parametrize('suffix', ['appex', 'APPEX'])
def test_extension_identity_is_checked_regardless_of_directory_case(tmp_path, suffix):
    directory = f'Game.app/PlugIns/Widget.{suffix}'
    archive = make_archive(tmp_path / 'game.zip', extra={
        f'{directory}/Info.plist': plistlib.dumps({
            'CFBundleIdentifier': 'io.someone.else', 'CFBundleExecutable': 'Widget'}),
        f'{directory}/Widget': binary(),
    })
    with pytest.raises(ArtifactError, match='Extension bundle ID'):
        inspect_archive(archive, 'io.test.prototype', '26.5')


def test_accepts_embedded_bundles_with_valid_metadata(tmp_path):
    extra = {}
    for directory, bundle_id in [('PlugIns/Widget.appex', 'io.test.prototype.widget'),
                                  ('Frameworks/Shared.framework', 'io.shared.library'),
                                  ('Nested.app', 'io.test.nested')]:
        extra[f'Game.app/{directory}/Info.plist'] = plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'Executable'})
        extra[f'Game.app/{directory}/Executable'] = binary(
            filetype=6 if directory.endswith('.framework') else 2)
    archive = make_archive(tmp_path / 'game.zip', extra=extra)
    assert inspect_archive(archive, 'io.test.prototype', '26.5')['mach_o_files'] == 4


def test_attestation_binds_source_signer_pin_and_runner(monkeypatch, tmp_path):
    captured = []
    def run(command, **kwargs):
        captured.append(command)
        return subprocess.CompletedProcess(command, 0, stdout=b'[]')
    monkeypatch.setattr(subprocess, 'run', run)
    policy = dict(repo='crew/day1', commit='a' * 40,
                  signer_workflow='crew/infra/.github/workflows/build.yml', signer_digest='b' * 40)
    verify_provenance(tmp_path / 'artifact.zip', **policy)
    command = captured[0]
    assert command[command.index('--source-digest') + 1] == 'a' * 40
    assert command[command.index('--signer-digest') + 1] == 'b' * 40
    assert '--deny-self-hosted-runners' in command
    monkeypatch.setattr(subprocess, 'run', lambda *a, **kw: subprocess.CompletedProcess(a[0], 1))
    with pytest.raises(ArtifactError, match='failed'):
        verify_provenance(tmp_path / 'artifact.zip', **policy)


def test_rejects_forged_decompressed_length_and_crc(tmp_path):
    import zlib
    archive = make_archive(tmp_path / 'forged.zip', extra={'Game.app/asset': b'x' * 10000})
    with zipfile.ZipFile(archive) as z:
        entry = z.getinfo('Game.app/asset')
        offset = entry.header_offset
    data = bytearray(archive.read_bytes())
    crc = zlib.crc32(b'x')
    struct.pack_into('<I', data, offset + 14, crc)
    struct.pack_into('<I', data, offset + 22, 1)
    cursor = data.index(b'PK\x01\x02')
    while True:
        name_size, extra_size, comment_size = struct.unpack_from('<3H', data, cursor + 28)
        name = bytes(data[cursor + 46:cursor + 46 + name_size])
        if name == b'Game.app/asset':
            struct.pack_into('<I', data, cursor + 16, crc)
            struct.pack_into('<I', data, cursor + 24, 1)
            break
        cursor += 46 + name_size + extra_size + comment_size
    archive.write_bytes(data)
    # Python's normal reader accepts the falsely short entry, so test the stronger check.
    with zipfile.ZipFile(archive) as z:
        assert z.read('Game.app/asset') == b'x'
    with pytest.raises(ArtifactError, match='Actual decompressed'):
        inspect_archive(archive, 'io.test.prototype', '26.5')
