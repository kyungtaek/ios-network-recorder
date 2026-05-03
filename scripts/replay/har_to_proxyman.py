#!/usr/bin/env python3
"""
har_to_proxyman.py — HAR → Proxyman Map Local import JSON 변환기

Usage:
    python3 har_to_proxyman.py input.har output.json [--strip-query] [--prefer-status 401]

출력 JSON은 proxyman-cli import --mode append --input output.json 으로 주입한다.
"""

import argparse
import base64
import json
import os
import random
import sys
from urllib.parse import urlparse, urlunparse


# ---------------------------------------------------------------------------
# HAR 로드
# ---------------------------------------------------------------------------

def load_har(path: str) -> list[dict]:
    """HAR / .nrsession 파일 파싱 후 entries 반환 (startedDateTime 기준 정렬)."""
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    # HAR 1.2 표준: log.entries
    entries = data.get("log", {}).get("entries", [])
    if not entries:
        # .nrsession 또는 flat 배열 형식
        entries = data if isinstance(data, list) else []

    # startedDateTime 기준 정렬 (없으면 파일 순서 유지)
    def sort_key(e: dict) -> str:
        return e.get("startedDateTime", "")

    entries.sort(key=sort_key)
    return entries


# ---------------------------------------------------------------------------
# URL 패턴 생성
# ---------------------------------------------------------------------------

def build_url_pattern(har_url: str, strip_all_query: bool = False) -> str:
    """
    HAR URL → Proxyman 와일드카드 패턴 변환.

    HAR URL은 이미 excludedQueryParams가 제거된 상태이므로
    stable params는 그대로 보존하고 끝에 * 를 붙인다.

    strip_all_query=True: 쿼리 전체 제거 후 ?* (param 순서 불일치 fallback)
    """
    parsed = urlparse(har_url)

    if strip_all_query:
        base = urlunparse(parsed._replace(query="", fragment=""))
        suffix = "?*" if parsed.query else "*"
        return base + suffix
    else:
        base = urlunparse(parsed._replace(fragment=""))
        return base + "*"


# ---------------------------------------------------------------------------
# raw HTTP 응답 생성
# ---------------------------------------------------------------------------

def build_raw_http(entry: dict) -> bytes:
    """
    HAR entry → raw HTTP 응답 바이트열.

    형식:
        HTTP/1.1 {status} {statusText}\n
        {Header-Name}: {value}\n
        ...
        \n
        {body}

    [REDACTED] 값을 가진 응답 헤더는 제거한다.
    """
    response = entry["response"]
    status = response.get("status", 200)
    status_text = response.get("statusText", "")
    headers = response.get("headers", [])
    content = response.get("content", {})
    body_text = content.get("text", "")

    lines = [f"HTTP/1.1 {status} {status_text}"]

    for h in headers:
        name = h.get("name", "")
        value = h.get("value", "")
        if value == "[REDACTED]":
            continue
        lines.append(f"{name}: {value}")

    lines.append("")  # 헤더-바디 구분 빈 줄
    header_part = "\n".join(lines) + "\n"

    encoding = content.get("encoding", "")
    if encoding == "base64" and body_text:
        return header_part.encode("utf-8") + base64.b64decode(body_text)
    else:
        return header_part.encode("utf-8") + (body_text or "").encode("utf-8")


# ---------------------------------------------------------------------------
# 규칙 ID / 이름 생성
# ---------------------------------------------------------------------------

def _make_rule_id() -> str:
    """8자리 대문자 hex ID."""
    return "".join(random.choices("0123456789ABCDEF", k=8))


def _make_rule_name(method: str, url: str) -> str:
    """har-replay-{METHOD}-{host}-{path-slug} 형식."""
    parsed = urlparse(url)
    host = parsed.hostname or "unknown"
    path = parsed.path.strip("/").replace("/", "-") or "root"
    return f"har-replay-{method.upper()}-{host}-{path}"


# ---------------------------------------------------------------------------
# 규칙 dict 생성
# ---------------------------------------------------------------------------

def entry_to_rule(entry: dict, strip_all_query: bool = False) -> dict:
    """HAR entry → Proxyman Map Local 규칙 dict."""
    request = entry["request"]
    method = request.get("method", "GET").upper()
    url = request.get("url", "")

    rule_id = _make_rule_id()
    name = _make_rule_name(method, url)
    url_pattern = build_url_pattern(url, strip_all_query=strip_all_query)

    raw_http = build_raw_http(entry)
    import_file_data = base64.b64encode(raw_http).decode("ascii")

    # Proxyman Map Local 파일 경로
    local_path = (
        f"~/Library/Application Support/com.proxyman.NSProxy/map-local/har-replay-{rule_id}.json"
    )

    # method 필드: ANY면 null, 특정 메서드면 exact 배열
    method_field = {"exact": [{"name": method}]}

    return {
        "nodeType": {
            "node": {
                "_0": {
                    "id": rule_id,
                    "name": name,
                    "url": url_pattern,
                    "method": method_field,
                    "regex": "useWildcard",
                    "isEnabled": True,
                    "isLocalFileEnable": True,
                    "isDirectoryFileEnable": False,
                    "isIncludingPaths": False,
                    "advanceSettings": None,
                    "graphQLQueryName": None,
                    "directoryFile": None,
                    "localFile": {
                        "path": local_path,
                        "name": f"har-replay-{rule_id}",
                        "importFileData": import_file_data,
                    },
                }
            }
        }
    }


# ---------------------------------------------------------------------------
# 중복 제거: 동일 method+URL에서 하나만 선택
# ---------------------------------------------------------------------------

def _dedup_entries(entries: list[dict], prefer_status: int | None) -> list[dict]:
    """
    동일 (method, url) 쌍에서 하나의 entry만 선택한다.

    prefer_status 지정 시: 해당 status code를 가진 entry 우선.
    없으면: startedDateTime 기준 첫 번째 (이미 정렬됨).
    """
    seen: dict[tuple, dict] = {}

    for entry in entries:
        request = entry["request"]
        method = request.get("method", "GET").upper()
        url = request.get("url", "")
        key = (method, url)

        if key not in seen:
            seen[key] = entry
        elif prefer_status is not None:
            current_status = seen[key]["response"].get("status")
            this_status = entry["response"].get("status")
            if this_status == prefer_status and current_status != prefer_status:
                seen[key] = entry

    return list(seen.values())


# ---------------------------------------------------------------------------
# import JSON 생성
# ---------------------------------------------------------------------------

def build_import_json(
    entries: list[dict],
    strip_all_query: bool = False,
    prefer_status: int | None = None,
) -> dict:
    """
    HAR entries → proxyman-cli import 용 JSON dict.

    구조:
        {
            "mapLocalData": {
                "isEnabled": true,
                "data": "<base64(JSON 배열)>"
            }
        }
    """
    deduped = _dedup_entries(entries, prefer_status)
    rules = [entry_to_rule(e, strip_all_query=strip_all_query) for e in deduped]
    rules_json = json.dumps(rules, ensure_ascii=False, separators=(",", ":"))
    rules_b64 = base64.b64encode(rules_json.encode("utf-8")).decode("ascii")

    return {
        "mapLocalData": {
            "isEnabled": True,
            "data": rules_b64,
        }
    }


# ---------------------------------------------------------------------------
# CLI main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="HAR 파일을 Proxyman Map Local import JSON으로 변환한다.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  python3 har_to_proxyman.py exported.har /tmp/proxyman-rules.json
  python3 har_to_proxyman.py exported.har /tmp/proxyman-rules.json --strip-query
  python3 har_to_proxyman.py exported.har /tmp/proxyman-rules.json --prefer-status 401
        """,
    )
    parser.add_argument("har", help="입력 HAR 파일 경로")
    parser.add_argument("output", help="출력 JSON 파일 경로 (- 는 stdout)")
    parser.add_argument(
        "--strip-query",
        action="store_true",
        help="전체 쿼리 파라미터 제거 후 ?* 패턴 사용 (param 순서 불일치 fallback)",
    )
    parser.add_argument(
        "--prefer-status",
        type=int,
        default=None,
        metavar="CODE",
        help="동일 URL에 복수 응답이 있을 때 선호할 HTTP status code (기본: 첫 번째)",
    )

    args = parser.parse_args()

    try:
        entries = load_har(args.har)
    except (FileNotFoundError, json.JSONDecodeError, KeyError) as e:
        print(f"ERROR: HAR 파일 로드 실패: {e}", file=sys.stderr)
        sys.exit(1)

    if not entries:
        print("WARNING: HAR 파일에 entries가 없습니다.", file=sys.stderr)

    result = build_import_json(
        entries,
        strip_all_query=args.strip_query,
        prefer_status=args.prefer_status,
    )

    output_str = json.dumps(result, indent=2, ensure_ascii=False)

    if args.output == "-":
        print(output_str)
    else:
        output_path = args.output
        # 출력 디렉토리 생성
        output_dir = os.path.dirname(os.path.abspath(output_path))
        os.makedirs(output_dir, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(output_str)
        rule_count = len(json.loads(
            base64.b64decode(result["mapLocalData"]["data"])
        ))
        print(f"변환 완료: {rule_count}개 규칙 → {output_path}")


if __name__ == "__main__":
    main()
