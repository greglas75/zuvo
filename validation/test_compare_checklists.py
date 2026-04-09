"""Tests for compare-checklists.py invariant scoring."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent / "compare-checklists.py"
INVARIANTS = Path(__file__).parent / "invariants" / "tgmcontest_orchestrator.json"

# Load invariants once for test data generation
with open(INVARIANTS) as f:
    ALL_INVARIANTS = json.load(f)


def run_script(checklist_path: str) -> tuple[int, dict]:
    """Run compare-checklists.py and return (exit_code, parsed_json)."""
    result = subprocess.run(
        [sys.executable, str(SCRIPT), checklist_path],
        capture_output=True,
        text=True,
    )
    return result.returncode, json.loads(result.stdout)


def make_checklist(tmp_path: Path, content: str) -> Path:
    """Write content to a temp file and return the path."""
    p = tmp_path / "checklist.md"
    p.write_text(content)
    return p


def build_perfect_content() -> str:
    """Build checklist content that matches ALL invariant patterns."""
    lines = [
        "# Test Checklist for tgmcontest ORCHESTRATOR",
        "",
        "## Middleware Order",
        "callOrder should equal requestId, errorHandler, corsMiddleware, dbMiddleware",
        "admin callOrder should have clerkAuth then tenantResolver",
        "public routes use publicTenantResolver middleware",
        "requestId runs before clerkAuth on admin routes",
        "",
        "## Route Mounting",
        "/api/admin/contests route mounted",
        "/api/admin draws route mounted",
        "/api/admin rewards route mounted",
        "/api/admin/translations route mounted",
        "/api/admin/tenant route mounted",
        "/api/contests public route mounted",
        "/api/translations public route mounted",
        "/api/r social redirect route",
        "/api/webhooks webhook routes mounted",
        "",
        "## Rate Limit Factory",
        "rateLimit(3, 3600) for register",
        "rateLimit(5, 3600) for verify-email",
        "rateLimit(10, 3600) for entry/*",
        "rateLimit(10, 60) for /r/*",
        "rateLimit(30, 60) for og-image",
        "rateLimit(60, 60) for winners",
        "",
        "## Rate Limit Path Binding",
        "/api/contests/slug/register with rateLimit(3, 3600) binding",
        "/api/contests/slug/verify-email with rateLimit(5, 3600) binding",
        "/api/contests/slug/entry/* with rateLimit(10, 3600) binding",
        "/api/r/* with rateLimit(10, 60) binding",
        "/api/contests/slug/og-image with rateLimit(30, 60) binding",
        "/api/contests/slug/winners with rateLimit(60, 60) binding",
        "",
        "## Auth Boundary Positive",
        "admin routes require clerkAuth in callOrder",
        "public contests routes use publicTenantResolver",
        "",
        "## Auth Boundary Negative",
        "public routes not toContain clerkAuth",
        "webhook routes not toContain clerkAuth",
        "health endpoint not toContain clerkAuth",
        "",
        "## Error Handling",
        "unknown path returns 404 not found",
        "",
        "## Health",
        "/api/health returns 200 with status ok",
    ]
    return "\n".join(lines)


class TestPerfectScore:
    def test_all_invariants_matched(self, tmp_path):
        path = make_checklist(tmp_path, build_perfect_content())
        exit_code, result = run_script(str(path))
        assert result["score"] == 1.0
        assert result["pass"] is True
        assert result["matched"] == result["total_required"]
        assert len(result["unmatched"]) == 0
        assert exit_code == 0


class TestPartialScore:
    def test_missing_some_invariants(self, tmp_path):
        # Only include middleware order, skip everything else
        content = "callOrder requestId errorHandler corsMiddleware dbMiddleware\nclerkAuth tenantResolver\npublicTenantResolver"
        path = make_checklist(tmp_path, content)
        exit_code, result = run_script(str(path))
        assert 0 < result["score"] < 1.0
        assert len(result["unmatched"]) > 0
        assert result["matched"] + len(result["unmatched"]) == result["total_required"]


class TestBelowThreshold:
    def test_below_80_percent_fails(self, tmp_path):
        # Very sparse content — only a few patterns match
        content = "some random test content with clerkAuth mentioned once"
        path = make_checklist(tmp_path, content)
        exit_code, result = run_script(str(path))
        assert result["pass"] is False
        assert exit_code == 1


class TestEmptyChecklist:
    def test_empty_file_scores_zero(self, tmp_path):
        path = make_checklist(tmp_path, "")
        exit_code, result = run_script(str(path))
        assert result["score"] == 0.0
        assert result["pass"] is False
        assert exit_code == 1


class TestJsonOutputFormat:
    def test_has_required_keys(self, tmp_path):
        path = make_checklist(tmp_path, "anything")
        _, result = run_script(str(path))
        required_keys = {"total_required", "matched", "unmatched", "score", "pass"}
        assert required_keys.issubset(result.keys())

    def test_types_are_correct(self, tmp_path):
        path = make_checklist(tmp_path, build_perfect_content())
        _, result = run_script(str(path))
        assert isinstance(result["total_required"], int)
        assert isinstance(result["matched"], int)
        assert isinstance(result["unmatched"], list)
        assert isinstance(result["score"], float)
        assert isinstance(result["pass"], bool)
