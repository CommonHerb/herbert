#!/usr/bin/env python3
"""Inspect ELF executable headers using Herbert's own runtime."""

from hexview_long64 import main


if __name__ == "__main__":
    raise SystemExit(main(program="elfinfo", description=__doc__))
