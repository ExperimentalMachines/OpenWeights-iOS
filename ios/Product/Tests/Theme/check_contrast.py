#!/usr/bin/env python3
"""Check declared sRGB tokens, without claiming rendered UI accessibility."""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / 'App/Theme.swift'
raw = source.read_bytes()
tokens = {name: {'light': int(light, 16), 'dark': int(dark, 16)} for name, light, dark in
          re.findall(r'static let (\w+) = adaptive\(light: 0x([0-9A-Fa-f]+), dark: 0x([0-9A-Fa-f]+)\)', raw.decode())}
fixed = {name: int(color, 16) for name, color in re.findall(r'static let (\w+) = Color\(hex: 0x([0-9A-Fa-f]+)\)', raw.decode())}


def luminance(color):
    values = [(color >> shift & 255) / 255 for shift in [16, 8, 0]]
    values = [value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4 for value in values]
    return sum(value * weight for value, weight in zip(values, [.2126, .7152, .0722]))


def contrast(first, second):
    low, high = sorted([luminance(first), luminance(second)])
    return (high + .05) / (low + .05)


checks = []
for appearance in ['light', 'dark']:
    for background in ['canvas', 'raised']:
        for foreground in ['text', 'secondary', 'signal', 'danger', 'outline']:
            ratio = contrast(tokens[foreground][appearance], tokens[background][appearance])
            minimum = 3 if foreground == 'outline' else 4.5
            checks.append({'appearance': appearance, 'foreground': foreground, 'background': background,
                           'ratio': round(ratio, 4), 'minimum': minimum, 'passed': ratio >= minimum})
ratio = contrast(fixed['ink'], fixed['lime'])
checks.append({'appearance': 'both', 'foreground': 'ink', 'background': 'lime', 'ratio': round(ratio, 4),
               'minimum': 4.5, 'passed': ratio >= 4.5})
assert all(check['passed'] for check in checks), 'Declared color-pair contrast failed.'
identity = hashlib.sha256(raw).hexdigest()
proof = {'status': 'declared-sRGB-token-contrast-verified', 'source': 'App/Theme.swift', 'sourceSHA256': identity,
         'checks': checks, 'limitations': ['Computed from declared source colors, not captured rendered UIKit pixels.',
                                         'Does not verify VoiceOver, focus, Dynamic Type, touch navigation or disabled-state rendering.']}
output = root / f'Results/theme-contrast-{identity[:12]}.json'
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(f'{len(checks)} declared color pairs pass. {output.name}')
