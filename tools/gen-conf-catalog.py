#!/usr/bin/env python3
"""The complex GUI's vocabulary, extracted from the core itself.

DOSBox-X ships a full reference conf - every section, key, default, help
text and possible-values list. The old Android app asked the running core
for this through JNI (the 804-line config-GUI patch); the Flutter launcher
reads it as a build-time asset instead, so the whole configuration surface
renders without the core in the launcher process, and a core bump refreshes
it by re-running this script.

    tools/gen-conf-catalog.py   # writes flutter_app/assets/conf_catalog.json
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'native', 'dosbox-x',
                   'dosbox-x.reference.full.conf')
OUT = os.path.join(HERE, '..', 'flutter_app', 'assets', 'conf_catalog.json')

sections = []
section = None
helps = {}
current_key = None
DEEP_INDENT = '                                                    '

for raw in open(SRC, encoding='utf-8', errors='replace'):
    line = raw.rstrip('\n')
    m = re.match(r'^\[(.+)\]\s*$', line)
    if m:
        section = {'name': m.group(1), 'options': []}
        sections.append(section)
        helps = {}
        current_key = None
        continue
    if section is None:
        continue
    if line.startswith('#'):
        body = line[1:]
        m = re.match(r'^\s{2,}([^:]{1,60}?):\s(.*)$', body)
        # A new "name: help" entry has the key right-aligned in the padding;
        # continuation lines are pushed to the deep-indent column.
        if m and not body.startswith(DEEP_INDENT):
            current_key = m.group(1).strip()
            helps[current_key] = [m.group(2).strip()]
        elif current_key:
            helps[current_key].append(body.strip())
        continue
    m = re.match(r'^([^=#]+?)\s*=\s*(.*)$', line)
    if m:
        key = m.group(1).strip()
        default = m.group(2).strip()
        values = []
        kept = []
        for h in helps.get(key, []):
            pv = re.match(r'^Possible values:\s*(.*?)\.?\s*$', h)
            if pv:
                values = [v.strip() for v in pv.group(1).split(',')
                          if v.strip()]
            else:
                kept.append(h)
        section['options'].append({
            'key': key,
            'default': default,
            'help': ' '.join(kept).strip(),
            'values': values,
        })

sections = [s for s in sections if s['options']]
os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump({'sections': sections}, open(OUT, 'w'), indent=1)
total = sum(len(s['options']) for s in sections)
print(f"{len(sections)} sections, {total} options -> {os.path.relpath(OUT)}")
