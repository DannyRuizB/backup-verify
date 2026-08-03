#!/usr/bin/env python3
"""Re-align a manifest's size and sha256 with its artefact.

Test helper only. A negative case that deliberately mutilates an artefact must
be able to target a LATER gate in verify.sh (the content comparison) without
being stopped by an EARLIER one (the checksum). Re-aligning the manifest is how
the case says "pretend this damaged file is what we backed up".
"""
import hashlib
import re
import sys

manifest, artefact = sys.argv[1], sys.argv[2]
data = open(artefact, 'rb').read()
text = open(manifest).read()
text = re.sub(r'"bytes":\s*\d+', '"bytes": %d' % len(data), text)
text = re.sub(r'"sha256":\s*"[^"]*"',
              '"sha256": "%s"' % hashlib.sha256(data).hexdigest(), text)
open(manifest, 'w').write(text)
