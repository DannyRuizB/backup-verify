#!/usr/bin/env python3
"""Corrupt one table fingerprint in a manifest, leaving everything else intact.

Test helper only. This reproduces the failure that a row count can never see:
the artefact is fine, the size and checksum match, the table has exactly the
right number of rows - and the CONTENT differs. If verify.sh accepted this, the
whole repo would be theatre.
"""
import re
import sys

manifest = sys.argv[1]
text = open(manifest).read()
new_text, n = re.subn(r'("customers":\s*")[0-9a-f]{32}(")',
                      r'\g<1>deadbeefdeadbeefdeadbeefdeadbeef\g<2>', text)
if n != 1:
    raise SystemExit('expected exactly one customers fingerprint, replaced %d' % n)
open(manifest, 'w').write(new_text)
