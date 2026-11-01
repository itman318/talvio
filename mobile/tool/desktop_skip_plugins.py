"""Hide a platform (linux / windows / macos) of some plugins, so Flutter doesn't build them for that desktop.
Usage: python3 tool/desktop_skip_plugins.py linux no_screenshot other_plugin ..."""
import json, os, sys
from urllib.parse import urlparse, unquote

platform, names = sys.argv[1], set(sys.argv[2:])
cfg = json.load(open('.dart_tool/package_config.json'))
for pkg in cfg['packages']:
    if pkg['name'] not in names:
        continue
    root = pkg['rootUri']
    if root.startswith('file:'):
        path = unquote(urlparse(root).path)
        if os.name == 'nt' and path.startswith('/'):
            path = path[1:]
    else:
        path = os.path.normpath(os.path.join('.dart_tool', root))
    spec = os.path.join(path, 'pubspec.yaml')
    lines = open(spec, encoding='utf-8').read().split('\n')
    out, skip_indent = [], None
    for ln in lines:
        stripped = ln.lstrip()
        indent = len(ln) - len(stripped)
        if skip_indent is not None:
            if stripped and indent <= skip_indent:
                skip_indent = None
            else:
                continue
        if stripped.rstrip() == platform + ':' and indent >= 6:
            skip_indent = indent
            continue
        out.append(ln)
    open(spec, 'w', encoding='utf-8').write('\n'.join(out))
    print('skipped', pkg['name'], 'on', platform)
