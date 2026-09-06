#!/usr/bin/env python3
"""Install two locally trusted test apps on a disposable simulator and remove it afterward."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import uuid


def simctl(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True, timeout=120).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('first', type=Path)
    parser.add_argument('second', type=Path)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--device-type', default='com.apple.CoreSimulator.SimDeviceType.iPhone-17')
    args = parser.parse_args()
    apps = [args.first.resolve(), args.second.resolve()]
    bundle_ids = [plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] for app in apps]
    if len(set(bundle_ids)) != 2:
        raise ValueError('The two variants must have different bundle IDs')
    device = simctl('create', 'Crew infrastructure check ' + uuid.uuid4().hex[:8], args.device_type, args.runtime)
    try:
        simctl('boot', device)
        simctl('bootstatus', device, '-b')
        for app in apps:
            simctl('install', device, str(app))
        for bundle in bundle_ids:
            assert simctl('get_app_container', device, bundle, 'app')
        containers = [simctl('get_app_container', device, bundle, 'data') for bundle in bundle_ids]
        assert containers[0] != containers[1]
        for bundle in bundle_ids:
            simctl('launch', device, bundle)
            simctl('terminate', device, bundle)
        print(json.dumps({'coexistence': 'passed', 'separate_data_containers': True,
                          'both_launch': True, 'bundle_ids': bundle_ids}, indent=2))
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
        simctl('delete', device)


if __name__ == '__main__':
    main()
