#!/usr/bin/env python3
"""Claude Code statusline for macOS.

- Shows model / context % / 5h % / 7d %
- Highlights the model name in red when it is Fable
- Posts a macOS notification once per threshold crossing
No network access. No LLM calls. Standard library only.

Port of windows/claude-statusline.ps1; the alert logic must stay identical (see README).
Written for the python3 that ships with the Xcode Command Line Tools (3.9), so no newer
syntax (match, X | Y type unions, ...).
"""
import json
import math
import os
import re
import subprocess
import sys

# ---- settings ----
THRESHOLDS = (50, 80, 95)       # percent
EXPENSIVE_RE = r'fable'         # model names to highlight (regex, case-insensitive)
HYSTERESIS = 5                  # percent points a value must drop below the last threshold to re-arm
STATE_FILE = os.path.join(os.path.expanduser('~'), '.claude', 'statusline-alert-state.json')
NOTIFY_SOUND = 'default'        # sound played with the notification: 'default', a name from
                                # /System/Library/Sounds (e.g. 'Glass'), or '' for silent

ESC = '\x1b'


def notify(message):
    """Post a notification and return at once; the statusline must not wait for it.

    The message is passed as an argument, not spliced into the AppleScript source.
    macOS shows it under "Script Editor" and keeps it in Notification Center.
    A silent notification is easy to miss, so a sound is on by default (NOTIFY_SOUND).
    """
    sound = ' sound name "' + NOTIFY_SOUND + '"' if NOTIFY_SOUND else ''
    script = ('on run argv\ndisplay notification (item 1 of argv) with title "Claude usage"'
              + sound + '\nend run')
    try:
        subprocess.Popen(['osascript', '-e', script, message],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def number(data, *path):
    """Walk nested dicts; return the value as a float, or None when it is absent."""
    for key in path:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    if isinstance(data, bool) or not isinstance(data, (int, float)):
        return None
    return float(data)


def load_state():
    state = {'five_hour': 0, 'seven_day': 0}
    try:
        with open(STATE_FILE) as f:
            saved = json.load(f)
        for key in state:
            state[key] = int(saved.get(key) or 0)
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return state


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)      # other sessions never see a half-written file
    except OSError:
        pass


def check_window(state, key, label, pct):
    """Threshold alert: once per crossing; re-arms when the window resets."""
    if pct is None:
        return
    last = state[key]
    if pct < last - HYSTERESIS:
        # Real drop (window reset): re-arm silently to the highest threshold already passed.
        # Small dips (stale snapshots from other terminals) are ignored.
        last = max([t for t in THRESHOLDS if t <= pct] or [0])
    hit = max([t for t in THRESHOLDS if last < t <= pct] or [0])
    if hit:
        last = hit
        notify('{0} usage {1} (crossed {2}%)'.format(label, fmt_pct(pct), hit))
    state[key] = last


def fmt_pct(value):
    if value is None:
        return '--'
    return '{0}%'.format(int(math.floor(value + 0.5)))   # round half up, like .NET "N0"


def paint(text, pct):
    if pct is None:
        return text
    if pct >= 80:
        return ESC + '[31m' + text + ESC + '[0m'          # red
    if pct >= 50:
        return ESC + '[33m' + text + ESC + '[0m'          # yellow
    return text


def run(raw):
    """Take the JSON Claude Code sends on stdin; return the statusline text."""
    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError('not an object')
    except ValueError:
        return '[statusline: bad input]'

    model = data.get('model')
    model = model.get('display_name') if isinstance(model, dict) else None
    model = '' if model is None else str(model)
    ctx = number(data, 'context_window', 'used_percentage')
    five = number(data, 'rate_limits', 'five_hour', 'used_percentage')
    week = number(data, 'rate_limits', 'seven_day', 'used_percentage')

    # ---- threshold alerts ----
    state = load_state()
    before = dict(state)
    check_window(state, 'five_hour', '5-hour', five)
    check_window(state, 'seven_day', 'Weekly', week)
    if state != before:
        save_state(state)

    # ---- render ----
    model_text = '[' + model + ']'
    if re.search(EXPENSIVE_RE, model, re.IGNORECASE):
        model_text = ESC + '[1;31m[!! ' + model + ' !!]' + ESC + '[0m'
    parts = [
        model_text,
        paint('ctx ' + fmt_pct(ctx), ctx),
        paint('5h ' + fmt_pct(five), five),
        paint('7d ' + fmt_pct(week), week),
    ]
    return ' | '.join(parts)


if __name__ == '__main__':
    sys.stdout.write(run(sys.stdin.buffer.read().decode('utf-8', 'replace')) + '\n')
