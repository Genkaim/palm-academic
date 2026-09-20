#!/usr/bin/env python3
"""Small stateful EAMS simulator for PalmAcademic debug builds."""

from __future__ import annotations

import argparse
import hashlib
import json
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


LOCK = threading.Lock()


def baseline_state() -> dict:
    return {
        "auth_expired": False,
        "courses": [],
        "grades": [["大学英语", "82"]],
        "exams": [["大学英语", "2026-12-18 10:00", "A101"]],
    }


STATE = baseline_state()


def apply_scenario(name: str) -> None:
    global STATE
    with LOCK:
        if name == "reset":
            STATE = baseline_state()
        elif name == "schedule_publish":
            STATE["courses"] = [
                {"courseId": "MATH101", "courseName": "高等数学", "teacher": "张老师", "room": "B201"}
            ]
        elif name == "schedule_change":
            if not STATE["courses"]:
                apply = {"courseId": "MATH101", "courseName": "高等数学", "teacher": "张老师", "room": "B201"}
                STATE["courses"] = [apply]
            STATE["courses"][0]["room"] = "B305"
        elif name == "grade_publish":
            STATE["grades"].append(["高等数学", "95"])
        elif name == "exam_publish":
            STATE["exams"].append(["高等数学", "2026-12-22 14:00", "B305"])
        elif name == "auth_expire":
            STATE["auth_expired"] = True
        elif name == "auth_restore":
            STATE["auth_expired"] = False
        else:
            raise ValueError(f"unknown scenario: {name}")


class Handler(BaseHTTPRequestHandler):
    server_version = "PalmAcademicMock/1.0"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[mock-eams] {self.address_string()} {fmt % args}", flush=True)

    def send_body(self, status: int, body: str, content_type: str = "text/html; charset=utf-8", headers=None) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        for key, value in headers or []:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, value: object, status: int = HTTPStatus.OK, headers=None) -> None:
        self.send_body(status, json.dumps(value, ensure_ascii=False), "application/json; charset=utf-8", headers)

    def authenticated(self) -> bool:
        with LOCK:
            expired = STATE["auth_expired"]
        return not expired and "SESSION=mock-session" in self.headers.get("Cookie", "")

    def require_auth(self) -> bool:
        if self.authenticated():
            return True
        self.send_response(HTTPStatus.FOUND)
        self.send_header("Location", "/student/login?expired=1")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/":
            self.send_body(HTTPStatus.OK, DASHBOARD)
        elif path == "/__test/state":
            with LOCK:
                self.send_json(STATE)
        elif path == "/__test/scenario":
            try:
                apply_scenario(parse_qs(parsed.query).get("name", [""])[0])
                with LOCK:
                    self.send_json(STATE)
            except ValueError as error:
                self.send_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
        elif path == "/student/login-salt":
            if "EAMS_PREAUTH=ready" not in self.headers.get("Cookie", ""):
                self.send_json({"error": "missing login pre-session"}, HTTPStatus.CONFLICT)
            else:
                self.send_body(HTTPStatus.OK, '"mock-salt"', "text/plain; charset=utf-8")
        elif path == "/student/login":
            self.send_body(
                HTTPStatus.OK,
                LOGIN_PAGE,
                headers=[("Set-Cookie", "EAMS_PREAUTH=ready; Path=/student; HttpOnly; SameSite=Lax")],
            )
        elif path == "/student/home":
            if self.require_auth():
                self.send_body(HTTPStatus.OK, HOME_PAGE)
        elif path == "/student/for-std/course-table":
            if self.require_auth():
                self.send_body(HTTPStatus.OK, COURSE_PAGE)
        elif path == "/student/for-std/course-table/get-data":
            if self.require_auth():
                with LOCK:
                    self.send_json(STATE["courses"])
        elif path == "/student/for-std/grade/sheet":
            if self.require_auth():
                with LOCK:
                    rows = "".join(f"<tr><td>{course}</td><td>{score}</td></tr>" for course, score in STATE["grades"])
                self.send_body(HTTPStatus.OK, f"<html><body><table><tr><th>课程</th><th>成绩</th></tr>{rows}</table></body></html>")
        elif path == "/student/for-std/exam-arrange":
            if self.require_auth():
                with LOCK:
                    rows = "".join(
                        f"<tr><td>{course}</td><td>{time}</td><td>{room}</td></tr>" for course, time, room in STATE["exams"]
                    )
                self.send_body(
                    HTTPStatus.OK,
                    f'<html><body><table class="exam-table"><tr><th>课程名称</th><th>时间</th><th>地点</th></tr>{rows}</table></body></html>',
                )
        else:
            self.send_body(HTTPStatus.NOT_FOUND, "not found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if path == "/student/login":
            if "EAMS_PREAUTH=ready" not in self.headers.get("Cookie", ""):
                self.send_json({"result": False, "needCaptcha": True, "message": "缺少登录预会话"})
                return
            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                payload = {}
            username = str(payload.get("username", ""))
            password_hash = str(payload.get("password", ""))
            if username == "captcha":
                self.send_json({"result": False, "needCaptcha": True, "message": "需要验证码"})
                return
            expected_hash = hashlib.sha1(b"mock-salt-test").hexdigest()
            if username != "test" or password_hash != expected_hash:
                self.send_json({"result": False, "needCaptcha": False, "message": "账号或密码错误"})
                return
            with LOCK:
                STATE["auth_expired"] = False
            self.send_json(
                {"result": True, "needCaptcha": False},
                headers=[("Set-Cookie", "SESSION=mock-session; Path=/student; HttpOnly; SameSite=Lax")],
            )
        else:
            self.send_body(HTTPStatus.NOT_FOUND, "not found", "text/plain; charset=utf-8")


LOGIN_PAGE = """<!doctype html><meta charset="utf-8"><title>登入页面</title>
<main id="vue_main"><h1>模拟教务登录</h1><form id="login"><input name="username" value="test">
<input name="password" type="password" value="test"><button>登录</button></form></main>
<script>login.onsubmit=async(e)=>{e.preventDefault();await fetch('/student/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test',password:'3dcff05503dfa260bc89489ba8a1944d88430f87'})});location='/student/home'}</script>"""

HOME_PAGE = """<!doctype html><meta charset="utf-8"><title>模拟教务首页</title>
<h1>掌上教务 localhost 测试站</h1><a href="/student/for-std/course-table">我的课表</a>"""

COURSE_PAGE = """<!doctype html><meta charset="utf-8"><title>我的课表</title>
<script>var semesterId = 20261;</script><h1>我的课表</h1>"""

DASHBOARD = """<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>掌上教务测试台</title>
<style>body{font-family:system-ui;max-width:760px;margin:40px auto;padding:0 20px}button{margin:6px;padding:10px 14px}</style>
<h1>掌上教务 localhost 测试台</h1><p>按钮会改变下一次 App 轮询得到的数据。</p>
<div id="buttons"></div><pre id="state"></pre><script>
const names=['reset','schedule_publish','schedule_change','grade_publish','exam_publish','auth_expire','auth_restore'];
for(const name of names){const b=document.createElement('button');b.textContent=name;b.onclick=async()=>{await fetch('/__test/scenario?name='+name);load()};buttons.append(b)}
async function load(){state.textContent=JSON.stringify(await (await fetch('/__test/state')).json(),null,2)}load();
</script></html>"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    print(f"PalmAcademic mock EAMS: http://{args.host}:{args.port}", flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
