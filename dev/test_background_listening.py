#!/usr/bin/env python3
"""Run real Android TTS with the app backgrounded and screen off.

Usage: python3 dev/test_background_listening.py --device ANDROID_SERIAL
The device must be unlocked and have a working system TTS voice.
Logs and the foreground-service snapshot are retained under /tmp.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    log_dir = Path(tempfile.mkdtemp(prefix='langhuan-background-tts-'))
    log = log_dir / 'flutter.log'

    def adb(*command):
        return subprocess.run(
            ['adb', '-s', args.device, *command],
            check=True, capture_output=True, text=True,
        ).stdout

    was_awake = 'mWakefulness=Awake' in adb('shell', 'dumpsys', 'power')
    backgrounded = False
    print(f'Test evidence: {log_dir}', flush=True)
    with log.open('w') as output:
        process = subprocess.Popen(
            ['flutter', 'test', 'integration_test/background_listening_test.dart',
             '-d', args.device, '--no-uninstall'],
            cwd=root, stdout=output, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 600
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError('Background TTS test exceeded 10 minutes')
                if not backgrounded and 'BACKGROUND_TTS_READY' in log.read_text():
                    adb('shell', 'input', 'keyevent', '3')
                    adb('shell', 'input', 'keyevent', '223')
                    backgrounded = True
                    time.sleep(1)
                    service = adb('shell', 'dumpsys', 'activity', 'services',
                                  'org.eu.ywxt.langhuan.dev')
                    (log_dir / 'foreground-service.txt').write_text(service)
                    if 'isForeground=true' not in service:
                        raise RuntimeError('Listening has no foreground service')
                    print('App backgrounded, screen off, foreground service verified', flush=True)
                time.sleep(.25)
            print(log.read_text())
            if process.returncode or not backgrounded:
                raise SystemExit(process.returncode or 1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if was_awake and backgrounded:
                adb('shell', 'input', 'keyevent', '224')


if __name__ == '__main__':
    main()
