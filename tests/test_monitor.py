import copy
import datetime as dt
import json
import os
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import sys
import subprocess
import plistlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
from monitor import Handler, LocalHTTPServer, Monitor, Store, TZ, changed_rows, scan_tree, validate_config


def snapshot(values, incomplete=(), root="/scope", depth=6):
    nodes = {}
    for path, size in values.items():
        rel = Path(path).relative_to(root)
        nodes[path] = {"bytes": size, "files": 1, "complete": path not in incomplete,
                       "root": root, "depth": len(rel.parts),
                       "parent": str(Path(path).parent) if path != root else None}
    return {"nodes": nodes, "roots": [root], "max_depth": depth, "errors": [],
            "counts": {"files": 1, "directories": len(nodes), "errors": len(incomplete)}}


DISK = SimpleNamespace(total=100_000_000_000, free=40_000_000_000)


class ScannerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_growth_new_removed_and_nested_aggregation(self):
        leaf = self.root / "cache" / "nested"
        leaf.mkdir(parents=True)
        f = leaf / "payload"
        f.write_bytes(b"x" * 4096)
        old = scan_tree([str(self.root)])
        f.write_bytes(b"x" * 1024 * 1024)
        (self.root / "new").mkdir()
        after = scan_tree([str(self.root)])
        changes = {r["path"]: r for r in changed_rows(old, after)}
        self.assertGreater(changes[str(leaf)]["delta"], 900_000)
        self.assertEqual(changes[str(leaf)]["delta"], changes[str(leaf.parent)]["delta"])
        self.assertEqual(changes[str(self.root / 'new')]["kind"], "new")
        f.unlink()
        leaf.rmdir()
        removed = {r["path"]: r for r in changed_rows(after, scan_tree([str(self.root)]))}
        self.assertEqual(removed[str(leaf)]["kind"], "removed")
        self.assertLess(removed[str(leaf)]["delta"], 0)

    def test_permission_loss_is_not_deletion_or_shrink(self):
        cache = self.root / "private"
        cache.mkdir()
        (cache / "nested").mkdir()
        (cache / "data").write_bytes(b"a" * 4096)
        old = scan_tree([str(self.root)])
        original = os.scandir
        def deny(path):
            if str(path) == str(cache):
                raise PermissionError("test denial")
            return original(path)
        with patch("monitor.os.scandir", side_effect=deny):
            current = scan_tree([str(self.root)])
        rows = {r["path"]: r for r in changed_rows(old, current)}
        self.assertEqual(current["counts"]["errors"], 1)
        self.assertFalse(current["nodes"][str(self.root)]["complete"])
        for path in [self.root, cache, cache / "nested"]:
            self.assertIsNone(rows[str(path)]["delta"])
            self.assertEqual(rows[str(path)]["kind"], "unknown")

    def test_symlinks_not_followed_and_hardlinks_counted_once(self):
        f = self.root / "a"
        f.write_bytes(b"a" * 1024 * 1024)
        os.link(f, self.root / "b")
        (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        result = scan_tree([str(self.root)])
        expected = self.root.stat().st_blocks * 512 + f.stat().st_blocks * 512 + (self.root / "loop").lstat().st_blocks * 512
        self.assertEqual(result["nodes"][str(self.root)]["bytes"], expected)
        self.assertEqual(result["counts"]["directories"], 1)

    def test_depth_limits_records_but_not_totals(self):
        leaf = self.root / "a" / "b" / "c"
        leaf.mkdir(parents=True)
        (leaf / "x").write_bytes(b"a" * 65536)
        full = scan_tree([str(self.root)], 8)
        shallow = scan_tree([str(self.root)], 1)
        self.assertNotIn(str(leaf), shallow["nodes"])
        self.assertEqual(full["nodes"][str(self.root)]["bytes"], shallow["nodes"][str(self.root)]["bytes"])
        # Changed record depth cannot invent deletion of formerly retained summaries.
        rows = {r["path"]: r for r in changed_rows(full, shallow)}
        self.assertIsNone(rows[str(leaf)]["delta"])

    def test_scanner_never_opens_file_contents(self):
        (self.root / "x").write_bytes(b"a")
        with patch("builtins.open", side_effect=AssertionError("content read")):
            scan_tree([str(self.root)])

    def test_cancel_does_not_commit_partial_results(self):
        stop = threading.Event()
        stop.set()
        with self.assertRaises(InterruptedError):
            scan_tree([str(self.root)], stop=stop)


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_compressed_snapshot_roundtrip(self):
        value = snapshot({"/scope": 10, "/scope/中文目录": 10})
        sid = self.store.save(value, 1_800_000_000, DISK)
        self.assertEqual(value, self.store.load(sid))

    def test_retention_thirty_days_with_daily_rollup_after_seven(self):
        value = snapshot({"/scope": 10})
        start = 1_800_000_000
        for h in range(35 * 24):
            self.store.save(value, start + h * 3600, DISK)
        history = self.store.history()
        last = history[-1]["started"]
        self.assertTrue(all(s["started"] >= last - 30 * 86400 for s in history))
        old = [s for s in history if s["started"] < last - 7 * 86400]
        days = [dt.datetime.fromtimestamp(s["started"], TZ).date() for s in old]
        self.assertEqual(len(days), len(set(days)))
        self.assertGreater(len(history), 168)
        self.assertLessEqual(len(history), 194)

    def test_today_baseline_and_short_history_notice(self):
        day = dt.datetime(2026, 10, 16, tzinfo=TZ).timestamp()
        for t in [day - 3600, day + 3600, day + 6 * 3600]:
            self.store.save(snapshot({"/scope": 10}), t, DISK)
        monitor = Monitor(self.tmp.name)
        result = monitor.dashboard("today")
        self.assertEqual(result["baseline"]["started"], day - 3600)
        week = monitor.dashboard("week")
        self.assertTrue(week["baseline_note"])

    def test_first_scan_has_no_fabricated_growth(self):
        self.store.save(snapshot({"/scope": 10}), 1_800_000_000, DISK)
        result = Monitor(self.tmp.name).dashboard()
        self.assertIsNone(result["baseline"])
        self.assertTrue(all(r["delta"] is None for r in result["rows"]))

    def test_changed_scope_is_unknown(self):
        old = snapshot({"/scope": 10, "/scope/a": 10})
        current = snapshot({"/other": 20}, root="/other")
        self.assertTrue(all(r["delta"] is None for r in changed_rows(old, current)))

    def test_overlapping_roots_rejected(self):
        parent = Path(self.tmp.name)
        child = parent / "child"
        child.mkdir()
        with self.assertRaisesRegex(ValueError, "互相包含"):
            validate_config({"roots": [str(parent), str(child)]})


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.server = LocalHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.monitor = Monitor(cls.tmp.name)
        cls.server.token = "test-token"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.tmp.cleanup()

    def call(self, path, data=None, headers=None):
        request = urllib.request.Request(self.url + path, data=data, headers=headers or {})
        return self.opener.open(request, timeout=5)

    def test_engine_serves_only_api(self):
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.call("/")
        self.assertEqual(err.exception.code, 404)
        err.exception.close()
        with self.call("/api/status") as r:
            self.assertIn("frame-ancestors 'none'", r.headers["Content-Security-Policy"])
            self.assertIsNone(json.load(r)["latest_id"])

    def test_host_rebinding_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.call("/api/status", headers={"Host": "evil.example"})
        self.assertEqual(err.exception.code, 403)
        err.exception.close()

    def test_write_without_token_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.call("/api/scan", b"{}")
        self.assertEqual(err.exception.code, 403)
        err.exception.close()

    def test_cross_origin_write_rejected_even_with_token(self):
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.call("/api/scan", b"{}", {"X-Storage-Token": "test-token", "Origin": "https://evil.example"})
        self.assertEqual(err.exception.code, 403)
        err.exception.close()

    def test_valid_scan_request(self):
        with patch.object(self.server.monitor, "trigger", return_value=True) as trigger:
            with self.call("/api/scan", b"{}", {"X-Storage-Token": "test-token"}) as r:
                self.assertTrue(json.load(r)["started"])
            trigger.assert_called_once()

    def test_path_traversal_has_no_file_reader(self):
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.call("/../../monitor.py")
        self.assertEqual(err.exception.code, 404)
        err.exception.close()


if __name__ == "__main__":
    unittest.main()
