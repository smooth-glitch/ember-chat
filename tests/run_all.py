"""Runs every test module against the server at EMBER_HOST:EMBER_PORT (default localhost:8099)."""
import importlib, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wsclient import summary

for module in ("test_messaging", "test_groups", "test_status_and_dms"):
    importlib.import_module(module)
sys.exit(summary())
