from __future__ import annotations

import os
import tempfile
from pathlib import Path

TMP_ROOT = (
    Path(__file__).resolve().parents[1] / ".pytest-tmp"
    if os.name == "nt"
    else Path(tempfile.gettempdir()) / "hep-data-web-pytest"
)
TMP_ROOT.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(TMP_ROOT)
