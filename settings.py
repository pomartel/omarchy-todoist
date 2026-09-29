#!/usr/bin/env python3
"""Private atomic settings persistence. JSON arrives only over stdin."""
import json
import os
from pathlib import Path
import sys
import tempfile


def prepare(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Invalid state directory')
    directory.chmod(0o700)
    target = directory / 'settings.json'
    if target.is_symlink():
        raise ValueError('Invalid settings file')
    if target.exists():
        target.chmod(0o600)
    return target


def write_settings(directory, text):
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError('Settings must be an object')
    target = prepare(directory)
    fd, temporary = tempfile.mkstemp(prefix='.settings-', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('--init', '--write'):
        return 2
    directory = Path(sys.argv[2])
    try:
        if sys.argv[1] == '--init':
            target = prepare(directory)
            if not target.exists():
                write_settings(directory, '{}')
        else:
            write_settings(directory, sys.stdin.read())
    except (OSError, ValueError):
        # Never echo JSON or token data into shell logs.
        print('Todoist settings operation failed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
