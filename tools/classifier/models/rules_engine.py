from __future__ import annotations

import time
from typing import Literal
from .base import BaseClassifier, ClassifyResponse


class RulesEngineClassifier(BaseClassifier):
    """Deterministic, zero-ML regex and token-based safety classifier."""

    DANGEROUS_PATTERNS = [
        ":(){", ":()", "while($true)", "while ($true)",
        "rm -rf /", "rm -fr /", "rm -rf /*", "rm -fr /*", "--no-preserve-root",
        "of=/dev/sd", "of=/dev/nvme", "of=/dev/vda", "of=/dev/hd", "of=/dev/mapper/",
        "of=/boot/", "of=/etc/", "of=/sys/", "of=/proc/",
        "mkfs.ext", "mkfs.xfs", "mkfs.btrfs", "mkfs.vfat", "mkfs.ntfs",
        "> /etc/", "> /boot/", "> /sys/", "> /proc/",
        "windows\\system32", "$env:systemroot", "$env:windir",
        "clear-recyclebin",
    ]

    def classify(self, command: str, cwd: str) -> ClassifyResponse:
        started = time.perf_counter()
        lower_cmd = command.lower()

        is_unsafe = False
        for pattern in self.DANGEROUS_PATTERNS:
            if pattern in lower_cmd:
                is_unsafe = True
                break

        # Check PowerShell Remove-Item root wipes
        if "remove-item" in lower_cmd and ("-recurse" in lower_cmd or "-force" in lower_cmd):
            if any(drive in lower_cmd for drive in ["c:\\", "c:/", "d:\\", "d:/", "$env:systemroot"]):
                is_unsafe = True

        label: Literal["safe", "unsafe"] = "unsafe" if is_unsafe else "safe"
        score = 0.99 if is_unsafe else 0.01
        latency = (time.perf_counter() - started) * 1000.0

        return ClassifyResponse(
            label=label,
            score=score,
            latency_ms=latency,
        )
