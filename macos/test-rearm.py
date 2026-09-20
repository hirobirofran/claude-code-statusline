#!/usr/bin/env python3
"""Scenario test for the threshold-alert (re-arm) logic in claude-statusline.py.

Why this exists:
    Same reason as windows/test-rearm.ps1. The alert logic is the only stateful part of the
    script and the part that has had a real bug on the Windows side (a small dip such as
    81% -> 79% re-fired the 50% alert). The scenarios and expected values are kept identical
    to the Windows test so both ports are held to the same behavior.
    Run this after touching check_window, THRESHOLDS or HYSTERESIS.
    How the notification looks and the colors are checked by eye on a Mac, not here.
    Not wired to any CI on purpose; run it by hand.

Usage:
    python3 macos/test-rearm.py
    Exit code: 0 = everything passed, 1 = something failed.
    It needs no Mac: it also runs on Windows/Linux, because the notifier is replaced.

How it stays safe:
    It loads the script as a module and swaps two names before calling run():
      - STATE_FILE points into a temp folder (the real ~/.claude state is untouched)
      - notify() records the message instead of calling osascript (nothing pops up)
    Every step calls run() with a fresh JSON payload, so state goes through the file
    each time, the same way separate statusline invocations do.
"""
import importlib.util
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'claude-statusline.py')

# Each step: (percent fed as the 5-hour usage, threshold expected to fire; 0 = silent).
SCENARIOS = [
    ('dips, window resets and re-crossings',
     [(81, 80), (79, 0), (80, 0), (49, 0), (58, 50), (96, 95), (3, 0), (52, 50)]),
    ('hysteresis boundary: a 5-point dip is ignored, 6 points re-arms silently',
     [(81, 80), (75, 0), (74, 0), (80, 80)]),
    ('jumping over several thresholds fires only the highest',
     [(10, 0), (97, 95)]),
]


def load_script():
    spec = importlib.util.spec_from_file_location('claude_statusline', SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    mod = load_script()
    fired = []
    mod.notify = fired.append
    failed = 0

    def check(ok, text):
        nonlocal failed
        if not ok:
            failed += 1
        print('{0}  {1}'.format('ok  ' if ok else 'FAIL', text))

    with tempfile.TemporaryDirectory() as tmp:
        mod.STATE_FILE = os.path.join(tmp, 'state.json')

        for name, steps in SCENARIOS:
            if os.path.exists(mod.STATE_FILE):
                os.remove(mod.STATE_FILE)
            print('\n== ' + name)
            for pct, expected in steps:
                del fired[:]
                mod.run(json.dumps({
                    'model': {'display_name': 'Sonnet 5'},
                    'context_window': {'used_percentage': 10},
                    'rate_limits': {'five_hour': {'used_percentage': pct}},
                }))
                m = re.search(r'crossed (\d+)%', fired[-1]) if fired else None
                got = int(m.group(1)) if m else 0
                check(got == expected and len(fired) <= 1,
                      '{0:3d}% -> fired {1:2d}  (expected {2:2d})'.format(pct, got, expected))

        print('\n== rendering and inputs without rate_limits')
        if os.path.exists(mod.STATE_FILE):
            os.remove(mod.STATE_FILE)
        del fired[:]
        line = mod.run(json.dumps({'model': {'display_name': 'Sonnet 5'},
                                   'context_window': {'used_percentage': 42.3}}))
        check(line == '[Sonnet 5] | ctx 42% | 5h -- | 7d --', 'no rate_limits -> ' + repr(line))
        check(not fired and not os.path.exists(mod.STATE_FILE),
              'no rate_limits -> no notification, state file not written')
        check(mod.run('not json') == '[statusline: bad input]', 'bad input -> placeholder text')

    print()
    if failed:
        print('FAILED: {0} check(s) did not match'.format(failed))
        return 1
    print('PASSED: all scenarios')
    return 0


if __name__ == '__main__':
    sys.exit(main())
