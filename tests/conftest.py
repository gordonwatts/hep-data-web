from __future__ import annotations

import tempfile
from pathlib import Path

TMP_ROOT = Path(tempfile.gettempdir()) / "hep-data-web-pytest"
TMP_ROOT.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(TMP_ROOT)
