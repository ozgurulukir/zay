# Zay Safety Classifier Service

This directory contains the optional REST service used to classify shell
commands. It provides `modernbert`, `rules`, and `llm-proxy` presets. If the
ModernBERT weight download fails, the loader falls back to the rules preset;
other model initialization errors are reported by the service.

For setup, configuration, Docker use, the REST contract, and the classifier's
limits, see the [Safety & Classifier Guide](../../docs/wiki/SAFETY_CLASSIFIER.md).
For project overview and installation, see the [root README](../../README.md).
