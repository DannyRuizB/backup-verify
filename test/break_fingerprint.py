#!/usr/bin/env python3
"""Corrupt one fingerprint in a manifest, leaving everything else intact.

Test helper only. This reproduces the failure that a count can never see:
the artefact is fine, the size and checksum match, the table (or file) has
exactly the right number of rows (or bytes) - and the CONTENT differs. If
verify.sh accepted this, the whole repo would be theatre.

Usage: break_fingerprint.py MANIFEST [KEY]
KEY defaults to "customers" (the database engines' seed table); the files
engine passes a file path from its seed instead. The hash half is 32 hex for
the md5-based engines and 64 for sha256, so both lengths are accepted - and
only the hash is corrupted, the ':<count>' half stays INTACT on purpose,
because that is the whole case: same count, different content.
"""
import re
import sys

manifest = sys.argv[1]
key = sys.argv[2] if len(sys.argv) > 2 else 'customers'
text = open(manifest).read()
new_text, n = re.subn(r'("%s":\s*")[0-9a-f]{32,64}(:\d+")' % re.escape(key),
                      r'\g<1>deadbeefdeadbeefdeadbeefdeadbeef\g<2>', text)
if n != 1:
    raise SystemExit('expected exactly one %s fingerprint, replaced %d' % (key, n))
open(manifest, 'w').write(new_text)
