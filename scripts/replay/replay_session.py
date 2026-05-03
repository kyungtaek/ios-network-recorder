#!/usr/bin/env python3
"""
replay_session.py — HAR Replay 생명주기 래퍼

Proxyman Map Local에 HAR 응답을 주입하고, 테스트 실행 후 자동으로 정리한다.

Usage:
    python3 replay_session.py --har exported.har                 # 대화형 모드
    python3 replay_session.py --har exported.har --dry-run       # 변환만 (주입 없음)
    python3 replay_session.py --har exported.har --strip-query   # 쿼리 전체 제거 패턴
    python3 replay_session.py --har exported.har --prefer-status 401
    python3 replay_session.py --har exported.har --exec 'xcodebuild test ...'

단계:
    1. preflight  — proxyman-cli 존재 + Proxyman 실행 확인
    2. backup     — 현재 설정 백업
    3. convert    — HAR → Map Local JSON 변환
    4. inject     — export → merge → Proxyman 종료 → import override → 재실행
    5. verify     — 규칙 존재 확인 + 샘플 요청 검증
    6. test-phase — --exec 실행 or 대화형 대기
    7. teardown   — export → har-replay-* 제거 → 종료 → import override → 재실행
"""

import argparse
import atexit
import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# 상수
# ---------------------------------------------------------------------------

PROXYMAN_CLI = "/Applications/Proxyman.app/Contents/MacOS/proxyman-cli"
PROXYMAN_PROXY = "http://127.0.0.1:9090"
LOG_PATH = Path(__file__).parent.parent.parent / "runs" / "replay-phase2" / "session.log"


# ---------------------------------------------------------------------------
# 로깅
# ---------------------------------------------------------------------------

def _log(agent: str, phase: str, action: str, status: str, summary: str) -> None:
    event = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "run_id": "replay-phase2",
        "agent": agent,
        "phase": phase,
        "action": action,
        "status": status,
        "summary": summary,
    }
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, ensure_ascii=False) + "\n")
    except OSError:
        pass  # 로그 실패는 무시


def log_info(phase: str, summary: str) -> None:
    _log("replay_session", phase, "task_start", "ok", summary)


def log_ok(phase: str, summary: str) -> None:
    _log("replay_session", phase, "task_complete", "ok", summary)


def log_fail(phase: str, summary: str) -> None:
    _log("replay_session", phase, "task_complete", "fail", summary)


# ---------------------------------------------------------------------------
# 상태 관리 (teardown용)
# ---------------------------------------------------------------------------

_state: dict = {
    "backup_path": None,        # 백업 JSON 경로
    "rules_path": None,         # 주입한 규칙 JSON 경로
    "injected": False,          # 실제 주입 완료 여부
    "injected_count": 0,        # 주입한 규칙 수
}


def _teardown() -> None:
    """atexit / signal 핸들러에서 호출: har-replay-* 규칙 제거."""
    if not _state["injected"]:
        return
    # 중복 실행 방지: 첫 번째 호출 이후 injected=False로 설정해 atexit 중복 차단
    _state["injected"] = False

    print("\n[replay] Teardown: har-replay-* 규칙 제거 중...", flush=True)
    log_info("teardown", "har-replay-* 규칙 teardown 시작")

    try:
        # 1. 현재 Proxyman 설정 export
        with tempfile.NamedTemporaryFile(
            suffix=".json", delete=False, mode="w"
        ) as tmp:
            current_path = tmp.name

        result = subprocess.run(
            [PROXYMAN_CLI, "export", "--output", current_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"[replay] WARN: export 실패: {result.stderr}", flush=True)
            log_fail("teardown", f"export 실패: {result.stderr.strip()}")
            return

        with open(current_path, "r", encoding="utf-8") as f:
            current_data = json.load(f)

        # 2. mapLocalData.data 에서 har-replay-* 규칙 제거
        removed = _remove_har_replay_rules(current_data)
        print(f"[replay] Teardown: {removed}개 har-replay-* 규칙 제거됨", flush=True)

        # 3. 정제된 설정 저장
        with tempfile.NamedTemporaryFile(
            suffix=".json", delete=False, mode="w", encoding="utf-8"
        ) as tmp:
            clean_path = tmp.name
            json.dump(current_data, tmp, ensure_ascii=False)

        try:
            os.unlink(current_path)
        except OSError:
            pass

        # 4. Proxyman 종료 (import는 실행 중 불가)
        _quit_proxyman()

        # 5. override import (규칙 복원)
        result = subprocess.run(
            [PROXYMAN_CLI, "import", "--mode", "override", "--input", clean_path],
            capture_output=True,
            text=True,
        )
        try:
            os.unlink(clean_path)
        except OSError:
            pass

        if result.returncode != 0:
            print(f"[replay] WARN: override import 실패: {result.stderr}", flush=True)
            log_fail("teardown", f"override import 실패: {result.stderr.strip()}")
        else:
            log_ok("teardown", f"teardown 완료: {removed}개 규칙 제거")

        # 6. Proxyman 재실행
        _launch_proxyman(3)
        print("[replay] Teardown 완료.", flush=True)

        # 7. 임시 파일 정리 (이미 삭제됨, 남은 것만)
        for p in [current_path, clean_path]:
            try:
                os.unlink(p)
            except OSError:
                pass

        # 6. 규칙 JSON 파일 정리
        if _state["rules_path"] and os.path.exists(_state["rules_path"]):
            try:
                os.unlink(_state["rules_path"])
            except OSError:
                pass

    except Exception as e:
        print(f"[replay] ERROR: teardown 실패: {e}", flush=True)
        log_fail("teardown", f"teardown 예외: {e}")


def _remove_har_replay_rules(data: dict) -> int:
    """
    mapLocalData.data (base64 JSON 배열) 에서 har-replay-* 규칙을 제거한다.
    변경된 data dict를 in-place 수정하고, 제거된 규칙 수를 반환한다.
    """
    map_local = data.get("mapLocalData", {})
    encoded = map_local.get("data", "")
    if not encoded:
        return 0

    try:
        rules = json.loads(base64.b64decode(encoded).decode("utf-8"))
    except Exception:
        return 0

    original_count = len(rules)
    filtered = [
        r for r in rules
        if not _is_har_replay_rule(r)
    ]

    removed = original_count - len(filtered)
    if removed > 0:
        new_encoded = base64.b64encode(
            json.dumps(filtered, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        data["mapLocalData"]["data"] = new_encoded

    return removed


def _is_har_replay_rule(rule: dict) -> bool:
    """규칙 dict에서 name이 'har-replay-' 로 시작하는지 확인."""
    try:
        name = rule["nodeType"]["node"]["_0"]["name"]
        return name.startswith("har-replay-")
    except (KeyError, TypeError):
        return False


def _signal_handler(signum, frame) -> None:
    print(f"\n[replay] Signal {signum} 수신, teardown 실행...", flush=True)
    _teardown()
    sys.exit(0)


# ---------------------------------------------------------------------------
# Proxyman 앱 생명주기 헬퍼
# ---------------------------------------------------------------------------

def _quit_proxyman(timeout: float = 6.0) -> bool:
    """Proxyman 종료 후 완전히 닫힐 때까지 대기. True=성공."""
    subprocess.run(
        ["osascript", "-e", 'tell application "Proxyman" to quit'],
        capture_output=True,
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(["pgrep", "-x", "Proxyman"], capture_output=True)
        if r.returncode != 0:
            return True
        time.sleep(0.3)
    return False


def _launch_proxyman(wait: float = 4.0) -> None:
    """Proxyman 재실행 후 프록시 준비 대기."""
    subprocess.run(["open", "-a", "Proxyman"])
    time.sleep(wait)


def _merge_map_local(base: dict, har_json: dict) -> dict:
    """base Proxyman 설정에 har_json의 Map Local 규칙을 append 병합한다."""
    import copy
    result = copy.deepcopy(base)

    base_ml = result.setdefault("mapLocalData", {})
    new_ml = har_json.get("mapLocalData", {})

    base_ml["isEnabled"] = True

    existing_rules: list = []
    if base_ml.get("data"):
        try:
            existing_rules = json.loads(base64.b64decode(base_ml["data"]).decode("utf-8"))
        except Exception:
            pass

    new_rules: list = []
    if new_ml.get("data"):
        try:
            new_rules = json.loads(base64.b64decode(new_ml["data"]).decode("utf-8"))
        except Exception:
            pass

    merged = existing_rules + new_rules
    base_ml["data"] = base64.b64encode(
        json.dumps(merged, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    return result


# ---------------------------------------------------------------------------
# Step 1: Preflight
# ---------------------------------------------------------------------------

def step_preflight() -> None:
    """proxyman-cli 존재 + Proxyman 실행 확인."""
    print("[replay] Step 1: Preflight...", flush=True)
    log_info("preflight", "proxyman-cli 및 Proxyman 실행 상태 확인")

    if not os.path.isfile(PROXYMAN_CLI):
        print(f"ERROR: proxyman-cli 없음: {PROXYMAN_CLI}", file=sys.stderr)
        log_fail("preflight", f"proxyman-cli 없음: {PROXYMAN_CLI}")
        sys.exit(1)

    # pgrep -x Proxyman
    result = subprocess.run(
        ["pgrep", "-x", "Proxyman"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print("ERROR: Proxyman이 실행 중이지 않습니다. 먼저 실행하세요.", file=sys.stderr)
        log_fail("preflight", "Proxyman 프로세스 없음")
        sys.exit(1)

    print("[replay] Preflight OK", flush=True)
    log_ok("preflight", "proxyman-cli 존재, Proxyman 실행 중 확인")


# ---------------------------------------------------------------------------
# Step 2: Backup
# ---------------------------------------------------------------------------

def step_backup() -> str:
    """현재 Proxyman 설정을 /tmp 에 백업."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    backup_path = f"/tmp/proxyman-backup-{ts}.json"
    print(f"[replay] Step 2: Backup → {backup_path}", flush=True)
    log_info("backup", f"Proxyman 설정 백업: {backup_path}")

    result = subprocess.run(
        [PROXYMAN_CLI, "export", "--output", backup_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: backup 실패: {result.stderr}", file=sys.stderr)
        log_fail("backup", f"export 실패: {result.stderr.strip()}")
        sys.exit(1)

    print(f"[replay] Backup 완료: {backup_path}", flush=True)
    log_ok("backup", f"백업 완료: {backup_path}")
    return backup_path


# ---------------------------------------------------------------------------
# Step 3: Convert
# ---------------------------------------------------------------------------

def step_convert(har_path: str, strip_query: bool, prefer_status: int | None) -> tuple[str, int]:
    """HAR → Map Local JSON 변환, 경로와 규칙 수 반환."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    rules_path = f"/tmp/har-rules-{ts}.json"
    print(f"[replay] Step 3: Convert {har_path} → {rules_path}", flush=True)
    log_info("convert", f"HAR 변환: {har_path}")

    script_dir = Path(__file__).parent
    converter = script_dir / "har_to_proxyman.py"

    cmd = [sys.executable, str(converter), har_path, rules_path]
    if strip_query:
        cmd.append("--strip-query")
    if prefer_status is not None:
        cmd.extend(["--prefer-status", str(prefer_status)])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: 변환 실패: {result.stderr}", file=sys.stderr)
        log_fail("convert", f"har_to_proxyman.py 실패: {result.stderr.strip()}")
        sys.exit(1)

    print(result.stdout.strip(), flush=True)

    # 규칙 수 확인
    with open(rules_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    rules = json.loads(base64.b64decode(data["mapLocalData"]["data"]).decode("utf-8"))
    rule_count = len(rules)

    log_ok("convert", f"변환 완료: {rule_count}개 규칙 → {rules_path}")
    return rules_path, rule_count


# ---------------------------------------------------------------------------
# Step 4: Inject
# ---------------------------------------------------------------------------

def step_inject(rules_path: str, rule_count: int) -> None:
    """
    proxyman-cli import는 Proxyman 실행 중 불가.
    export → merge → Proxyman 종료 → import override → 재실행.
    """
    print(f"[replay] Step 4: Inject {rule_count}개 규칙...", flush=True)
    log_info("inject", f"{rule_count}개 규칙 주입 시작")

    # 1. 현재 설정 export (실행 중에도 가능)
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        current_path = tmp.name
    result = subprocess.run(
        [PROXYMAN_CLI, "export", "--output", current_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: export 실패: {result.stderr}", file=sys.stderr)
        log_fail("inject", f"export 실패: {result.stderr.strip()}")
        sys.exit(1)

    # 2. HAR 규칙 병합
    with open(current_path, "r", encoding="utf-8") as f:
        current_data = json.load(f)
    with open(rules_path, "r", encoding="utf-8") as f:
        har_data = json.load(f)

    try:
        os.unlink(current_path)
    except OSError:
        pass

    merged_data = _merge_map_local(current_data, har_data)

    with tempfile.NamedTemporaryFile(
        suffix=".json", delete=False, mode="w", encoding="utf-8"
    ) as tmp:
        merged_path = tmp.name
        json.dump(merged_data, tmp, ensure_ascii=False)

    # 3. Proxyman 종료
    print("[replay] Proxyman 종료 중...", flush=True)
    if not _quit_proxyman():
        print("[replay] WARN: Proxyman 종료 타임아웃", flush=True)

    # 4. 병합된 설정 import (--mode override, Proxyman 종료 상태)
    result = subprocess.run(
        [PROXYMAN_CLI, "import", "--mode", "override", "--input", merged_path],
        capture_output=True,
        text=True,
    )
    try:
        os.unlink(merged_path)
    except OSError:
        pass

    if result.returncode != 0:
        print(f"ERROR: inject 실패: {result.stderr}", file=sys.stderr)
        log_fail("inject", f"import 실패: {result.stderr.strip()}")
        _launch_proxyman()
        sys.exit(1)

    # 5. Proxyman 재실행 (프록시 준비 대기)
    print("[replay] Proxyman 재실행 중...", flush=True)
    _launch_proxyman()

    _state["injected"] = True
    _state["injected_count"] = rule_count
    print(f"[replay] Inject 완료: {rule_count}개 규칙 주입됨", flush=True)
    log_ok("inject", f"{rule_count}개 규칙 주입 완료, Map Local 활성화")


# ---------------------------------------------------------------------------
# Step 5: Verify
# ---------------------------------------------------------------------------

def _get_injected_rule_names() -> list[str]:
    """현재 Proxyman에서 har-replay-* 규칙 이름 목록 반환."""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        result = subprocess.run(
            [PROXYMAN_CLI, "export", "--output", tmp_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return []

        with open(tmp_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        map_local = data.get("mapLocalData", {})
        encoded = map_local.get("data", "")
        if not encoded:
            return []

        rules = json.loads(base64.b64decode(encoded).decode("utf-8"))
        names = []
        for r in rules:
            try:
                name = r["nodeType"]["node"]["_0"]["name"]
                if name.startswith("har-replay-"):
                    names.append(name)
            except (KeyError, TypeError):
                pass
        return names
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _verify_sample_requests(rules_json_path: str) -> tuple[int, int]:
    """
    GET 엔드포인트 최대 3개에 대해 Proxyman 프록시를 통한 샘플 요청 검증.
    (pass_count, total_count) 반환.
    """
    with open(rules_json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    rules = json.loads(base64.b64decode(data["mapLocalData"]["data"]).decode("utf-8"))

    # GET 규칙만, 최대 3개
    get_rules = []
    for r in rules:
        try:
            node = r["nodeType"]["node"]["_0"]
            method_field = node.get("method", {})
            exact_list = method_field.get("exact", [])
            method = exact_list[0]["name"] if exact_list else "ANY"
            if method.upper() == "GET":
                get_rules.append(node)
        except (KeyError, TypeError, IndexError):
            pass

    get_rules = get_rules[:3]

    pass_count = 0
    total = len(get_rules)

    proxy_handler = urllib.request.ProxyHandler({"http": PROXYMAN_PROXY, "https": PROXYMAN_PROXY})
    opener = urllib.request.build_opener(proxy_handler)

    for node in get_rules:
        url_pattern = node.get("url", "")
        # 패턴에서 * 제거해 실제 URL 복원
        url = url_pattern.rstrip("*")
        if url.endswith("?"):
            url = url[:-1]

        # importFileData에서 기대 status 파싱
        expected_status = 200
        try:
            raw = base64.b64decode(node["localFile"]["importFileData"]).decode("utf-8")
            first_line = raw.split("\n")[0]
            expected_status = int(first_line.split()[1])
        except (KeyError, IndexError, ValueError):
            pass

        try:
            req = urllib.request.Request(url)
            resp = opener.open(req, timeout=5)
            actual_status = resp.status
        except urllib.error.HTTPError as e:
            actual_status = e.code
        except Exception as e:
            print(f"  [verify] WARN: {url} 요청 실패: {e}", flush=True)
            continue

        if actual_status == expected_status:
            print(f"  [verify] PASS: {url} → {actual_status}", flush=True)
            pass_count += 1
        else:
            print(f"  [verify] FAIL: {url} → 실제 {actual_status}, 기대 {expected_status}", flush=True)

    return pass_count, total


def step_verify(rules_path: str, expected_count: int, force: bool) -> None:
    """규칙 존재 확인 + 샘플 요청 검증."""
    print("[replay] Step 5: Verify...", flush=True)
    log_info("verify", "주입된 규칙 존재 및 샘플 요청 검증")

    # 5a. 규칙 존재 확인
    injected_names = _get_injected_rule_names()
    actual_count = len(injected_names)
    if actual_count < expected_count:
        print(
            f"  [verify] WARN: 기대 {expected_count}개, 실제 {actual_count}개 규칙 확인됨",
            flush=True,
        )
    else:
        print(f"  [verify] 규칙 확인: {actual_count}개 har-replay-* 규칙 존재", flush=True)

    # 5b. 샘플 요청 검증
    print("[replay] 샘플 요청 검증 중...", flush=True)
    try:
        pass_count, total = _verify_sample_requests(rules_path)
    except Exception as e:
        print(f"  [verify] WARN: 샘플 요청 검증 오류: {e}", flush=True)
        pass_count, total = 0, 0

    # 5c. 결과 평가
    if total == 0:
        print("  [verify] 샘플 GET 요청 없음 (건너뜀)", flush=True)
        log_ok("verify", "규칙 확인 완료, 샘플 요청 없음")
        return

    success_rate = pass_count / total if total > 0 else 1.0
    print(f"  [verify] 검증 결과: {pass_count}/{total} 성공", flush=True)

    if success_rate < 1.0 and not force:
        print(
            "  [verify] WARN: 일부 샘플 요청이 기대값과 불일치합니다.",
            flush=True,
        )
        print("  계속 진행하려면 Enter를 누르세요 (중단: Ctrl+C): ", end="", flush=True)
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            print("\n[replay] 사용자 중단.", flush=True)
            _teardown()
            sys.exit(1)

    log_ok("verify", f"검증 완료: {pass_count}/{total} 성공")


# ---------------------------------------------------------------------------
# Step 6: Test Phase
# ---------------------------------------------------------------------------

def step_test_phase(exec_cmd: str | None) -> int:
    """--exec 모드 또는 대화형 대기."""
    if exec_cmd:
        print(f"[replay] Step 6: exec 모드 실행: {exec_cmd}", flush=True)
        log_info("test-phase", f"exec 모드: {exec_cmd}")
        result = subprocess.run(exec_cmd, shell=True)
        rc = result.returncode
        if rc == 0:
            log_ok("test-phase", f"exec 완료: returncode={rc}")
        else:
            log_fail("test-phase", f"exec 실패: returncode={rc}")
        return rc
    else:
        print("\n[replay] Step 6: 대화형 모드", flush=True)
        print("[replay] Map Local 규칙이 활성 상태입니다.", flush=True)
        print("[replay] 테스트 완료 후 Enter를 눌러 teardown하세요 (Ctrl+C도 가능): ", end="", flush=True)
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            pass
        return 0


# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------

def run_dry(har_path: str, strip_query: bool, prefer_status: int | None) -> None:
    """변환 결과만 stdout 출력, 실제 주입 없음."""
    print("[replay] Dry-run 모드: 변환 결과만 출력합니다.", flush=True)
    log_info("dry-run", f"dry-run 시작: {har_path}")

    script_dir = Path(__file__).parent
    converter = script_dir / "har_to_proxyman.py"

    cmd = [sys.executable, str(converter), har_path, "-"]
    if strip_query:
        cmd.append("--strip-query")
    if prefer_status is not None:
        cmd.extend(["--prefer-status", str(prefer_status)])

    result = subprocess.run(cmd, text=True)
    if result.returncode != 0:
        log_fail("dry-run", "변환 실패")
        sys.exit(1)

    log_ok("dry-run", "dry-run 변환 완료")


# ---------------------------------------------------------------------------
# CLI main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="HAR 파일을 Proxyman Map Local에 주입해 재생하는 생명주기 래퍼",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  python3 replay_session.py --har exported.har                  # 대화형
  python3 replay_session.py --har exported.har --dry-run        # 변환만
  python3 replay_session.py --har exported.har --strip-query    # 쿼리 제거 패턴
  python3 replay_session.py --har exported.har --prefer-status 401
  python3 replay_session.py --har exported.har --exec 'xcodebuild test ...'
        """,
    )
    parser.add_argument("--har", required=True, help="입력 HAR 파일 경로")
    parser.add_argument(
        "--exec",
        dest="exec_cmd",
        default=None,
        metavar="CMD",
        help="테스트 명령 (완료 후 자동 teardown)",
    )
    parser.add_argument(
        "--strip-query",
        action="store_true",
        help="전체 쿼리 제거 패턴 사용 (--strip-query 플래그를 har_to_proxyman.py에 전달)",
    )
    parser.add_argument(
        "--prefer-status",
        type=int,
        default=None,
        metavar="CODE",
        help="동일 URL 복수 응답 중 선호 status code",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="변환 결과만 출력하고 실제 주입은 하지 않음",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="verify 실패 시 확인 없이 계속 진행",
    )

    args = parser.parse_args()

    # dry-run 모드
    if args.dry_run:
        run_dry(args.har, args.strip_query, args.prefer_status)
        return

    # signal 핸들러 등록 (teardown 보장)
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    # atexit 등록 (teardown 보장)
    atexit.register(_teardown)

    log_info("bootstrap", f"replay_session.py 시작: {args.har}")

    # Step 1: Preflight
    step_preflight()

    # Step 2: Backup
    backup_path = step_backup()
    _state["backup_path"] = backup_path

    # Step 3: Convert
    rules_path, rule_count = step_convert(args.har, args.strip_query, args.prefer_status)
    _state["rules_path"] = rules_path

    # Step 4: Inject
    step_inject(rules_path, rule_count)

    # Step 5: Verify
    step_verify(rules_path, rule_count, args.force)

    # Step 6: Test Phase
    rc = step_test_phase(args.exec_cmd)

    # Step 7: Teardown (atexit가 실행하지만 명시적으로도 호출)
    # _teardown() 내부에서 _state["injected"] = False 설정하므로 atexit 중복 차단됨
    _teardown()

    log_ok("complete", f"replay_session 완료: returncode={rc}")
    sys.exit(rc)


if __name__ == "__main__":
    main()
