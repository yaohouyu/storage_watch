#!/usr/bin/env python3
"""Local, metadata-only macOS storage history. Python standard library only."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import errno
import fcntl
import gzip
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import socketserver
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE = Path(__file__).resolve().parent
TZ = dt.timezone(dt.timedelta(hours=8))
DEFAULT = {
    "roots": [str(Path.home()), "/Applications", "/Library", "/private/var"],
    "interval_minutes": 60, "max_depth": 6,
    "alert_gb": 5, "notifications": False,
}


def iso(ts):
    return dt.datetime.fromtimestamp(ts, TZ).isoformat(timespec="seconds")


def validate_config(value):
    roots = value.get("roots")
    if not isinstance(roots, list) or not 1 <= len(roots) <= 12:
        raise ValueError("请选择 1–12 个扫描目录。")
    clean = []
    for raw in roots:
        if not isinstance(raw, str) or not raw.strip():
            raise ValueError("目录路径不能为空。")
        p = Path(raw.strip()).expanduser().resolve()
        if not p.is_dir():
            raise ValueError(f"目录不存在或无法访问：{p}")
        if any(p == old or p in old.parents or old in p.parents for old in clean):
            raise ValueError("扫描目录不能重复或互相包含。")
        clean.append(p)
    interval = int(value.get("interval_minutes", 60))
    depth = int(value.get("max_depth", 6))
    alert = float(value.get("alert_gb", 5))
    if not 15 <= interval <= 1440:
        raise ValueError("记录间隔需要在 15–1440 分钟之间。")
    if not 2 <= depth <= 12:
        raise ValueError("保留目录层级需要在 2–12 之间。")
    if not 0.1 <= alert <= 1000:
        raise ValueError("提醒阈值需要在 0.1–1000 GB 之间。")
    return {"roots": [str(p) for p in clean], "interval_minutes": interval,
            "max_depth": depth, "alert_gb": alert,
            "notifications": bool(value.get("notifications", False))}


def scan_tree(roots, max_depth=6, progress=None, stop=None):
    """Visit every accessible directory; retain summaries through max_depth.

    Allocated blocks are estimates on APFS: clones can share extents. No file
    contents are opened, symbolic links aren't followed, other volumes excluded.
    Missing permissions propagate to ancestors, never silently become zero.
    """
    nodes, errors, seen_links = {}, [], set()
    counts = {"files": 0, "directories": 0, "errors": 0, "current_path": ""}

    def record_error(path, kind, detail=""):
        counts["errors"] += 1
        if len(errors) < 300:
            errors.append({"path": str(path), "kind": kind, "detail": str(detail)})

    def visit(path, root, depth, device):
        if stop and stop.is_set():
            raise InterruptedError("扫描已停止")
        counts["directories"] += 1
        counts["current_path"] = str(path)
        if progress and counts["directories"] % 100 == 1:
            progress(dict(counts))
        total, files, complete = 0, 0, True
        try:
            info = os.stat(path, follow_symlinks=False)
            if device is not None and info.st_dev != device:
                record_error(path, "other_volume", "其他卷未扫描")
                complete = False
            else:
                device = info.st_dev
                total = info.st_blocks * 512
                with os.scandir(path) as it:
                    entries = sorted(it, key=lambda e: e.name)
                for e in entries:
                    if stop and stop.is_set():
                        raise InterruptedError("扫描已停止")
                    try:
                        s = e.stat(follow_symlinks=False)
                        if stat.S_ISDIR(s.st_mode):
                            b, f, c = visit(e.path, root, depth + 1, device)
                            total += b
                            files += f
                            complete = complete and c
                        else:
                            counts["files"] += 1
                            files += 1
                            key = (s.st_dev, s.st_ino)
                            if s.st_nlink > 1 and not stat.S_ISLNK(s.st_mode):
                                if key in seen_links:
                                    continue
                                seen_links.add(key)
                            total += s.st_blocks * 512
                    except OSError as exc:
                        record_error(e.path, "unreadable", exc)
                        complete = False
        except OSError as exc:
            record_error(path, "unreadable", exc)
            complete = False
        except RecursionError:
            record_error(path, "too_deep", "目录层级超出扫描器限制")
            complete = False
        if depth <= max_depth:
            nodes[str(path)] = {"bytes": total, "files": files,
                                "complete": complete, "root": root,
                                "parent": str(Path(path).parent) if depth else None,
                                "depth": depth}
        return total, files, complete

    for root in roots:
        visit(root, root, 0, None)
    if progress:
        progress(dict(counts))
    return {"nodes": nodes, "errors": errors, "counts": counts,
            "roots": roots, "max_depth": max_depth}


def changed_rows(before, after):
    """Comparable totals only; inaccessible/missing coverage stays unknown."""
    old, new = before["nodes"], after["nodes"]
    rows = []
    for path in old.keys() | new.keys():
        a, b = old.get(path), new.get(path)
        same_scope = (a or b)["root"] in set(before["roots"]) & set(after["roots"])
        # A summary absent because depth changed must not look removed/new.
        depth = (a or b)["depth"]
        covered = same_scope and depth <= min(before["max_depth"], after["max_depth"])
        def missing_is_known(tree, existing):
            # Find closest retained ancestor, which may also have disappeared.
            p = Path(path).parent
            while str(p) not in tree and str(p) != str(p.parent):
                p = p.parent
            ancestor = tree.get(str(p))
            return bool(ancestor and ancestor["complete"])
        known = covered and (a["complete"] if a else missing_is_known(old, b)) and (
            b["complete"] if b else missing_is_known(new, a))
        av, bv = a["bytes"] if a else 0, b["bytes"] if b else 0
        rows.append({"path": path, "parent": (a or b)["parent"],
                     "depth": depth, "root": (a or b)["root"],
                     "before": av if a or known else None,
                     "after": bv if b or known else None,
                     "delta": bv - av if known else None,
                     "kind": ("grown" if bv > av else "shrunk" if bv < av else "same")
                             if a and b and known else
                             "new" if not a and known else "removed" if not b and known else "unknown",
                     "complete": bool(known), "exists": b is not None,
                     "before_complete": a["complete"] if a else known,
                     "after_complete": b["complete"] if b else known})
    return rows


class Store:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.db = self.directory / "history.sqlite3"
        with self.connect() as c:
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("""CREATE TABLE IF NOT EXISTS scans (
                id INTEGER PRIMARY KEY, started REAL, finished REAL, total INTEGER,
                free INTEGER, errors INTEGER, files INTEGER, directories INTEGER,
                payload BLOB NOT NULL)""")
            c.execute("CREATE INDEX IF NOT EXISTS scan_time ON scans(started)")

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.db, timeout=30)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def save(self, result, started, disk):
        payload = gzip.compress(json.dumps(result, ensure_ascii=False,
                                           separators=(",", ":")).encode(), compresslevel=5)
        with self.connect() as c:
            row = c.execute("INSERT INTO scans VALUES(NULL,?,?,?,?,?,?,?,?)",
                            (started, time.time(), disk.total, disk.free,
                             result["counts"]["errors"], result["counts"]["files"],
                             result["counts"]["directories"], payload))
            scan_id = row.lastrowid
            # Full hourly history for 7 days, one final scan/day thereafter, 30 days total.
            c.execute("DELETE FROM scans WHERE started < ?", (started - 30 * 86400,))
            old = c.execute("SELECT id, started FROM scans WHERE started < ? ORDER BY started DESC",
                            (started - 7 * 86400,)).fetchall()
            days, remove = set(), []
            for sid, stamp in old:
                day = iso(stamp)[:10]
                if day in days:
                    remove.append((sid,))
                days.add(day)
            c.executemany("DELETE FROM scans WHERE id=?", remove)
        return scan_id

    def history(self):
        with self.connect() as c:
            c.row_factory = sqlite3.Row
            return [dict(r) for r in c.execute("SELECT id,started,finished,total,free,errors,files,directories FROM scans ORDER BY started")]

    def load(self, scan_id):
        with self.connect() as c:
            row = c.execute("SELECT payload FROM scans WHERE id=?", (scan_id,)).fetchone()
        if not row:
            raise ValueError("找不到这份记录，可能已超过保留期限。")
        return json.loads(gzip.decompress(row[0]))


class Monitor:
    def __init__(self, data):
        self.store = Store(data)
        self.config_path = Path(data) / "settings.json"
        self.config = dict(DEFAULT)
        if self.config_path.exists():
            self.config.update(json.loads(self.config_path.read_text()))
        self.lock = threading.RLock()
        self.stop = threading.Event()
        self.scan_thread = None
        history = self.store.history()
        last = history[-1]["finished"] if history else 0
        self.state = {"scanning": False, "progress": {}, "last_error": None,
                      "next_scan": max(time.time(), last + self.config["interval_minutes"] * 60),
                      "scan_started": None}

    def update_config(self, value):
        config = validate_config(value)
        with self.lock:
            if self.state["scanning"]:
                raise ValueError("正在扫描，请等扫描结束后再修改设置。")
            temp = self.config_path.with_suffix(".tmp")
            temp.write_text(json.dumps(config, ensure_ascii=False, indent=2))
            temp.replace(self.config_path)
            changed = (config["roots"], config["max_depth"]) != (self.config["roots"], self.config["max_depth"])
            self.config = config
            self.state["next_scan"] = time.time() if changed else time.time() + config["interval_minutes"] * 60
        return config

    def trigger(self):
        with self.lock:
            if self.state["scanning"]:
                return False
            self.state.update(scanning=True, progress={}, last_error=None, scan_started=time.time())
            config = dict(self.config)
            self.scan_thread = threading.Thread(target=self._scan, args=(config,), daemon=True)
            self.scan_thread.start()
        return True

    def _scan(self, config):
        started = time.time()
        try:
            def progress(p):
                with self.lock:
                    self.state["progress"] = p
            result = scan_tree(config["roots"], config["max_depth"], progress, self.stop)
            disk = shutil.disk_usage(Path.home())
            history = self.store.history()
            old = self.store.load(history[-1]["id"]) if config["notifications"] and history else None
            self.store.save(result, started, disk)
            if old:
                changes = changed_rows(old, result)
                growth = max((r for r in changes if r["delta"] is not None),
                             key=lambda r: r["delta"], default=None)
                if growth and growth["delta"] >= config["alert_gb"] * 1e9:
                    message = f'{Path(growth["path"]).name} 增长了 {growth["delta"] / 1e9:.1f} GB，请打开看板查看。'
                    # Pass message as argv, never interpolate filesystem paths into AppleScript.
                    script = 'on run argv\ndisplay notification (item 1 of argv) with title "Storage Watch"\nend run'
                    try:
                        subprocess.run(["/usr/bin/osascript", "-e", script, message], timeout=10,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except (OSError, subprocess.TimeoutExpired):
                        pass
        except InterruptedError:
            pass
        except Exception as exc:
            with self.lock:
                self.state["last_error"] = f"扫描未完成：{exc}"
        finally:
            with self.lock:
                self.state.update(scanning=False, next_scan=time.time() + config["interval_minutes"] * 60)

    def schedule(self):
        while not self.stop.is_set():
            with self.lock:
                due = not self.state["scanning"] and time.time() >= self.state["next_scan"]
            if due:
                self.trigger()
            self.stop.wait(2)

    def dashboard(self, period="previous", baseline=None):
        history = self.store.history()
        with self.lock:
            state = json.loads(json.dumps(self.state))
            config = dict(self.config)
        disk = shutil.disk_usage(Path.home())
        response = {"state": state, "config": config, "history": history,
                    "disk": {"total": disk.total, "free": disk.free},
                    "rows": [], "latest": None, "baseline": None,
                    "errors": [], "baseline_note": "", "alert": None}
        if not history:
            return response
        latest = history[-1]
        current = self.store.load(latest["id"])
        response.update(latest=latest, errors=current["errors"], roots=current["roots"],
                        max_depth=current["max_depth"])
        candidates = history[:-1]
        selected = None
        if baseline:
            selected = next((s for s in candidates if s["id"] == baseline), None)
            if not selected:
                raise ValueError("请选择早于最新记录的基线。")
        elif candidates and period == "previous":
            selected = candidates[-1]
        elif candidates and period in {"today", "week"}:
            stamp = dt.datetime.fromtimestamp(latest["started"], TZ)
            target = stamp.replace(hour=0, minute=0, second=0, microsecond=0).timestamp() if period == "today" else latest["started"] - 7 * 86400
            earlier = [s for s in candidates if s["started"] <= target]
            selected = earlier[-1] if earlier else candidates[0]
            if not earlier:
                response["baseline_note"] = "记录尚未覆盖整个时段，已使用最早可用记录。"
        response["baseline"] = selected
        if selected:
            before = self.store.load(selected["id"])
            rows = changed_rows(before, current)
            if before["roots"] != current["roots"] or before["max_depth"] != current["max_depth"]:
                response["baseline_note"] += " 扫描范围或保留层级已改变，仅比较双方覆盖的目录。"
            response["rows"] = rows
            # Display alert only against immediately preceding scan, independent of UI period.
            previous = before if selected["id"] == history[-2]["id"] else self.store.load(history[-2]["id"])
            immediate = rows if previous is before else changed_rows(previous, current)
            growing = [r for r in immediate if r["delta"] is not None and r["delta"] >= config["alert_gb"] * 1e9]
            if growing:
                response["alert"] = max(growing, key=lambda r: r["delta"])
        else:
            response["rows"] = [{"path": p, "parent": n["parent"], "depth": n["depth"],
                                 "root": n["root"], "before": None, "after": n["bytes"],
                                 "delta": None, "kind": "baseline", "complete": n["complete"],
                                 "exists": True, "before_complete": False,
                                 "after_complete": n["complete"]} for p, n in current["nodes"].items()]
        return response

    def summary(self):
        history = self.store.history()
        with self.lock:
            state = json.loads(json.dumps(self.state))
        disk = shutil.disk_usage(Path.home())
        return {"state": state, "latest_id": history[-1]["id"] if history else None,
                "disk": {"total": disk.total, "free": disk.free},
                "config": dict(self.config)}


class LocalHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # No hostname/reverse-DNS lookup: startup must work quickly while offline.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    server_version = "StorageBoard/1.0"

    def log_message(self, fmt, *args):
        # Keep logs small. The dashboard polls every 6 seconds.
        if args and str(args[1] if len(args) > 1 else "") not in {"200", "304"}:
            super().log_message(fmt, *args)

    def valid_host(self):
        port = self.server.server_port
        return self.headers.get("Host") in {f"127.0.0.1:{port}", f"localhost:{port}"}

    def send(self, status, body, content_type="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if not self.valid_host():
            return self.send(403, {"error": "只允许本机访问。"})
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        try:
            if parsed.path == "/api/health":
                return self.send(200, {"app": "storage-board", "pid": os.getpid()})
            if parsed.path == "/api/session":
                return self.send(200, {"token": self.server.token})
            if parsed.path == "/api/status":
                return self.send(200, self.server.monitor.summary())
            if parsed.path == "/api/dashboard":
                baseline = int(params["baseline"][0]) if params.get("baseline") else None
                payload = self.server.monitor.dashboard(params.get("period", ["previous"])[0], baseline)
                payload["token"] = self.server.token
                return self.send(200, payload)
            if parsed.path == "/api/export":
                history = self.server.monitor.store.history()
                return self.send(200, {"exported_at": iso(time.time()), "history": history})
            return self.send(404, {"error": "找不到页面。"})
        except (ValueError, KeyError) as exc:
            self.send(400, {"error": str(exc)})
        except Exception as exc:
            self.send(500, {"error": f"读取失败：{exc}"})

    def do_POST(self):
        if not self.valid_host():
            return self.send(403, {"error": "只允许本机访问。"})
        origin = self.headers.get("Origin")
        allowed = {f"http://127.0.0.1:{self.server.server_port}", f"http://localhost:{self.server.server_port}"}
        if origin and origin not in allowed:
            return self.send(403, {"error": "来源不被允许。"})
        if not secrets.compare_digest(self.headers.get("X-Storage-Token", ""), self.server.token):
            return self.send(403, {"error": "页面已过期，请刷新后再试。"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 32768:
                return self.send(413, {"error": "请求过大。"})
            value = json.loads(self.rfile.read(length)) if length else {}
            if self.path == "/api/scan":
                return self.send(200, {"started": self.server.monitor.trigger()})
            if self.path == "/api/settings":
                return self.send(200, self.server.monitor.update_config(value))
            if self.path == "/api/reveal":
                path = str(Path(value["path"]).expanduser())
                history = self.server.monitor.store.history()
                if not history or path not in self.server.monitor.store.load(history[-1]["id"])["nodes"]:
                    raise ValueError("只能打开最新扫描记录中的目录。")
                if not Path(path).is_dir():
                    raise ValueError("目录已经不存在。")
                subprocess.Popen(["/usr/bin/open", "-R", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return self.send(200, {"ok": True})
            if self.path == "/api/stop":
                self.send(200, {"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            return self.send(404, {"error": "找不到操作。"})
        except (ValueError, KeyError, TypeError) as exc:
            self.send(400, {"error": str(exc)})
        except Exception as exc:
            self.send(500, {"error": f"操作失败：{exc}"})


def main():
    parser = argparse.ArgumentParser(description="Storage Watch 本机采集引擎")
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--data-dir", type=Path, default=BASE / "data")
    parser.add_argument("--once", action="store_true", help="只采集一次，不启动服务")
    parser.add_argument("--auto-port", action="store_true", help="默认端口被占用时选择其他本机端口")
    parser.add_argument("--background-log", action="store_true", help="由采集器自身打开本地日志")
    parser.add_argument("--parent-pid", type=int, help="父应用退出时自动停止采集器")
    parser.add_argument("--release", help="采集器所属应用版本标识")
    args = parser.parse_args()
    args.data_dir.mkdir(parents=True, exist_ok=True)
    if args.background_log:
        output = (args.data_dir / "monitor.log").open("w", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = output
    # This same lock covers --once and server, preventing two writers/scanners.
    lock_file = (args.data_dir / "server.lock").open("a+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("采集器已经在运行。", flush=True)
        return
    monitor = Monitor(args.data_dir)
    try:
        os.nice(10)
    except OSError:
        pass
    if args.once:
        monitor.trigger()
        monitor.scan_thread.join()
        print(json.dumps(monitor.state, ensure_ascii=False))
        return
    try:
        server = LocalHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as exc:
        if not args.auto_port or exc.errno != errno.EADDRINUSE:
            raise
        server = LocalHTTPServer(("127.0.0.1", 0), Handler)
    server.monitor, server.token = monitor, secrets.token_urlsafe(32)
    runtime = args.data_dir / "runtime.json"
    runtime.write_text(json.dumps({"pid": os.getpid(), "port": server.server_port,
                                   "release": args.release}))
    scheduler = threading.Thread(target=monitor.schedule, daemon=True)
    scheduler.start()

    if args.parent_pid:
        def watch_parent():
            while not monitor.stop.wait(3):
                try:
                    os.kill(args.parent_pid, 0)
                except ProcessLookupError:
                    threading.Thread(target=server.shutdown, daemon=True).start()
                    return
                except PermissionError:
                    return

        threading.Thread(target=watch_parent, daemon=True).start()

    def shutdown(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(f"Storage Watch: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        monitor.stop.set()
        scheduler.join(timeout=3)
        if monitor.scan_thread:
            monitor.scan_thread.join(timeout=10)
        server.server_close()
        runtime.unlink(missing_ok=True)
        lock_file.close()


if __name__ == "__main__":
    main()
