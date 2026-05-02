#!/usr/bin/env python3
"""
ios-network-recorder 멀티에이전트 자율 실행 하네스.

pm 에이전트를 반복 호출하며 session.log 상태를 관찰, 종료 조건을 판정한다.
pm은 session.log를 읽어 현재 phase를 파악하고 다음 에이전트를 라우팅한다.

Usage:
    uv run python scripts/harness.py                               # 대화형 (human gate 활성)
    uv run python scripts/harness.py --run-id 20260430T172700-x    # 기존 run 재개
    uv run python scripts/harness.py --auto --budget-minutes 60    # 완전 자동
    uv run python scripts/harness.py --max-iter 3 --budget-minutes 30
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
RUNS_DIR = PROJECT_ROOT / "runs"


# ---------------------------------------------------------------------------
# Run directory helpers
# ---------------------------------------------------------------------------

def new_run_id(phase_slug: str = "bootstrap") -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"{ts}-{phase_slug}"


def run_dir(run_id: str) -> Path:
    return RUNS_DIR / run_id


def ensure_run_dir(run_id: str) -> None:
    (run_dir(run_id) / "handoffs").mkdir(parents=True, exist_ok=True)


def config_path(run_id: str) -> Path:
    return run_dir(run_id) / "config.json"


def log_path(run_id: str) -> Path:
    return run_dir(run_id) / "session.log"


def write_config(run_id: str, cfg: dict) -> None:
    config_path(run_id).write_text(json.dumps(cfg, indent=2))


def read_config(run_id: str) -> dict:
    p = config_path(run_id)
    if p.exists():
        return json.loads(p.read_text())
    return {}


# ---------------------------------------------------------------------------
# Session log helpers
# ---------------------------------------------------------------------------

def append_log(run_id: str, event: dict) -> None:
    event.setdefault("ts", datetime.now(timezone.utc).isoformat())
    event.setdefault("run_id", run_id)
    with log_path(run_id).open("a") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def read_log_events(run_id: str) -> list[dict]:
    p = log_path(run_id)
    if not p.exists():
        return []
    events = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def last_event(run_id: str) -> dict | None:
    events = read_log_events(run_id)
    return events[-1] if events else None


def count_consecutive_failures(run_id: str) -> int:
    events = read_log_events(run_id)
    count = 0
    for ev in reversed(events):
        if ev.get("status") in ("blocked", "escalate"):
            count += 1
        elif ev.get("status") == "ok":
            break
    return count


def elapsed_minutes(run_id: str) -> float:
    events = read_log_events(run_id)
    if not events:
        return 0.0
    try:
        start = datetime.fromisoformat(events[0]["ts"])
        now = datetime.now(timezone.utc)
        return (now - start).total_seconds() / 60
    except Exception:
        return 0.0


# ---------------------------------------------------------------------------
# pm agent invocation
# ---------------------------------------------------------------------------

def invoke_pm(run_id: str, task_context: str = "") -> str:
    task_section = f"\n\n[현재 태스크]\n{task_context}" if task_context else ""
    prompt = (
        f"run_id: {run_id}\n"
        f"runs 디렉토리: {run_dir(run_id)}\n"
        f"project 루트: {PROJECT_ROOT}{task_section}\n\n"
        "session.log를 읽고 현재 phase를 파악한 뒤, 다음 라우팅 액션을 실행하라.\n"
        "모든 액션 후 session.log에 JSONL 형식으로 기록하라.\n"
        "human_gate가 필요한 경우 session.log에 action:human_gate를 기록하고 중단하라.\n"
        "작업이 완료되거나 중단 조건에 도달하면 session.log에 run_end 또는 escalate를 기록하라."
    )
    result = subprocess.run(
        ["claude", "-p", prompt, "--agent", "pm"],
        capture_output=False,
        text=True,
        cwd=str(PROJECT_ROOT),
    )
    return "" if result.returncode != 0 else "ok"


# ---------------------------------------------------------------------------
# Human gate I/O
# ---------------------------------------------------------------------------

def handle_human_gate(run_id: str, event: dict, auto: bool) -> bool:
    """Returns True to continue, False to abort."""
    if auto:
        append_log(run_id, {
            "agent": "harness",
            "phase": event.get("phase", "unknown"),
            "action": "human_gate",
            "refs": event.get("refs", []),
            "summary": "auto mode: gate auto-approved",
            "status": "ok",
            "next": event.get("next", ""),
        })
        return True

    print("\n" + "=" * 60)
    print(f"[HUMAN GATE] Run {run_id}")
    print(f"Phase: {event.get('phase', '?')} | Summary: {event.get('summary', '')}")
    print("=" * 60)
    print("Type APPROVE to continue, REJECT to abort: ", end="", flush=True)

    try:
        decision = input().strip().upper()
    except (EOFError, KeyboardInterrupt):
        decision = "REJECT"

    approved = decision == "APPROVE"
    append_log(run_id, {
        "agent": "harness",
        "phase": event.get("phase", "unknown"),
        "action": "human_gate",
        "refs": event.get("refs", []),
        "summary": f"human decision: {decision}",
        "status": "ok" if approved else "halt",
        "next": event.get("next", "") if approved else "",
    })
    return approved


# ---------------------------------------------------------------------------
# Run summary
# ---------------------------------------------------------------------------

def print_summary(run_id: str) -> None:
    events = read_log_events(run_id)
    total = len(events)
    agents = {}
    for ev in events:
        a = ev.get("agent", "unknown")
        agents[a] = agents.get(a, 0) + 1

    last = events[-1] if events else {}
    print("\n" + "=" * 60)
    print(f"Run summary: {run_id}")
    print(f"  Total events: {total}")
    print(f"  Agent activity: {agents}")
    print(f"  Final status: {last.get('status', 'unknown')}")
    print(f"  Final summary: {last.get('summary', '')}")
    print(f"  Elapsed: {elapsed_minutes(run_id):.1f} min")
    print("=" * 60)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="ios-network-recorder 멀티에이전트 하네스")
    parser.add_argument("--run-id", help="재개할 run_id (없으면 새 run 생성)")
    parser.add_argument("--task-file", help="태스크 킥오프 문서 경로 (PM에 컨텍스트 주입)")
    parser.add_argument("--auto", action="store_true", help="Human gate 없이 완전 자동 실행")
    parser.add_argument("--budget-minutes", type=int, default=120, help="최대 실행 시간 (분, 기본 120)")
    parser.add_argument("--max-iter", type=int, default=10, help="최대 라우팅 이터레이션 (기본 10)")
    parser.add_argument("--failure-limit", type=int, default=3, help="연속 실패 한계 (기본 3)")
    args = parser.parse_args()

    task_context = ""
    if args.task_file:
        task_path = Path(args.task_file)
        if task_path.exists():
            task_context = task_path.read_text()
            print(f"[harness] Task file: {task_path.name}")

    run_id = args.run_id or new_run_id()
    ensure_run_dir(run_id)

    cfg = {
        "max_iterations": args.max_iter,
        "budget_minutes": args.budget_minutes,
        "auto": args.auto,
        "consecutive_failure_limit": args.failure_limit,
    }
    existing_cfg = read_config(run_id)
    if not existing_cfg:
        write_config(run_id, cfg)
        print(f"[harness] New run: {run_id}")
    else:
        cfg = {**cfg, **existing_cfg}
        print(f"[harness] Resuming run: {run_id}")

    print(f"[harness] Config: max_iter={cfg['max_iterations']}, budget={cfg['budget_minutes']}min, auto={cfg['auto']}")
    print(f"[harness] Log: {log_path(run_id)}")

    for iteration in range(cfg["max_iterations"]):
        print(f"\n[harness] Iteration {iteration + 1}/{cfg['max_iterations']}")

        # 예산 체크
        elapsed = elapsed_minutes(run_id)
        if elapsed > cfg["budget_minutes"]:
            print(f"[harness] Budget exceeded ({elapsed:.1f} min > {cfg['budget_minutes']} min)")
            append_log(run_id, {
                "agent": "harness",
                "phase": "decide",
                "action": "run_end",
                "refs": [],
                "summary": f"budget exceeded after {elapsed:.1f} min",
                "status": "halt",
                "next": "",
            })
            break

        # pm 호출
        invoke_pm(run_id, task_context=task_context)

        # 마지막 이벤트 확인
        ev = last_event(run_id)
        if ev is None:
            print("[harness] Warning: session.log empty after pm invocation")
            continue

        status = ev.get("status", "")
        action = ev.get("action", "")

        # 종료 조건
        if status == "halt":
            print(f"[harness] Halt: {ev.get('summary', '')}")
            break

        if status == "escalate":
            print(f"[harness] Escalation required: {ev.get('summary', '')}")
            print("[harness] Check session.log and handoffs/ for details.")
            break

        # Human gate
        if action == "human_gate":
            if not handle_human_gate(run_id, ev, cfg["auto"]):
                print("[harness] Human rejected. Halting.")
                break

        # 연속 실패 체크
        failures = count_consecutive_failures(run_id)
        if failures >= cfg["consecutive_failure_limit"]:
            print(f"[harness] Consecutive failures ({failures}) reached limit ({cfg['consecutive_failure_limit']})")
            append_log(run_id, {
                "agent": "harness",
                "phase": ev.get("phase", "unknown"),
                "action": "run_end",
                "refs": [],
                "summary": f"consecutive_failures={failures}, halting",
                "status": "escalate",
                "next": "",
            })
            break

    else:
        print(f"[harness] Max iterations ({cfg['max_iterations']}) reached")
        append_log(run_id, {
            "agent": "harness",
            "phase": "decide",
            "action": "run_end",
            "refs": [],
            "summary": f"max_iterations={cfg['max_iterations']} reached",
            "status": "halt",
            "next": "",
        })

    print_summary(run_id)


if __name__ == "__main__":
    main()
