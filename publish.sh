#!/usr/bin/env bash
# Query runner DB → generate data/state.json → commit & push to GitHub Pages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${SCRIPT_DIR}/../tasku/.db/runner.db"

if [ ! -f "$DB" ]; then
  echo "Error: runner.db not found at $DB" >&2
  exit 1
fi

# sqlite3 -json returns "" for empty results; normalize to "[]"
q() {
  local result
  result=$(sqlite3 -json "$DB" "$1" 2>/dev/null) || true
  if [ -z "$result" ]; then echo "[]"; else echo "$result"; fi
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Service status
TIMER_ACTIVE=$(systemctl --user is-active claude-runner.timer 2>/dev/null || echo "inactive")
NEXT_RUN=$(systemctl --user show claude-runner.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")

# Running sessions
RUNNING=$(q "
  SELECT type, repo, ref, tmux_session, started_at, duration FROM (
    SELECT 'issue' as type, r.name as repo, '#'||i.issue_number as ref, i.tmux_session, i.started_at,
      CAST((julianday('now') - julianday(i.started_at)) * 24 AS INT) || 'h ' ||
      CAST(((julianday('now') - julianday(i.started_at)) * 1440) % 60 AS INT) || 'm' as duration
    FROM issue_runs i JOIN repos r ON i.repo_id=r.id WHERE i.status='running'
    UNION ALL
    SELECT 'pr_fix', r.name, 'PR#'||p.pr_number, p.tmux_session, p.started_at,
      CAST((julianday('now') - julianday(p.started_at)) * 24 AS INT) || 'h ' ||
      CAST(((julianday('now') - julianday(p.started_at)) * 1440) % 60 AS INT) || 'm' as duration
    FROM pr_fix_runs p JOIN repos r ON p.repo_id=r.id WHERE p.status='running'
    UNION ALL
    SELECT 'workflow', 'workflow', '#'||issue_number, tmux_session, started_at,
      CAST((julianday('now') - julianday(started_at)) * 24 AS INT) || 'h ' ||
      CAST(((julianday('now') - julianday(started_at)) * 1440) % 60 AS INT) || 'm' as duration
    FROM workflow_runs WHERE status='running'
  ) ORDER BY started_at
")

# Pending / clarifying
PENDING=$(q "
  SELECT type, repo, ref, status, created_at FROM (
    SELECT 'issue' as type, r.name as repo, '#'||i.issue_number as ref, i.status, i.created_at
    FROM issue_runs i JOIN repos r ON i.repo_id=r.id WHERE i.status IN ('pending','clarifying')
    UNION ALL
    SELECT 'pr_fix', r.name, 'PR#'||p.pr_number, p.status, p.created_at
    FROM pr_fix_runs p JOIN repos r ON p.repo_id=r.id WHERE p.status='pending'
    UNION ALL
    SELECT 'workflow', 'workflow', '#'||issue_number, status, created_at
    FROM workflow_runs WHERE status='pending'
  ) ORDER BY created_at
")

# Recent completed/failed
RECENT=$(q "
  SELECT type, repo, ref, status, completed_at, error_message FROM (
    SELECT 'issue' as type, r.name as repo, '#'||i.issue_number as ref, i.status, i.completed_at, i.error_message
    FROM issue_runs i JOIN repos r ON i.repo_id=r.id WHERE i.status IN ('completed','failed')
    UNION ALL
    SELECT 'pr_fix', r.name, 'PR#'||p.pr_number, p.status, p.completed_at, p.error_message
    FROM pr_fix_runs p JOIN repos r ON p.repo_id=r.id WHERE p.status IN ('completed','failed')
    UNION ALL
    SELECT 'workflow', 'workflow', '#'||issue_number, status, completed_at, error_message
    FROM workflow_runs WHERE status IN ('completed','failed')
  ) ORDER BY completed_at DESC LIMIT 10
")

# Last events
EVENTS=$(q "
  SELECT run_type, event, message, created_at
  FROM run_log ORDER BY created_at DESC LIMIT 10
")

# Stats (use printf %d to strip whitespace)
TOTAL_COMPLETED=$(printf '%d' "$(sqlite3 "$DB" "SELECT COUNT(*) FROM (SELECT id FROM issue_runs WHERE status='completed' UNION ALL SELECT id FROM pr_fix_runs WHERE status='completed' UNION ALL SELECT id FROM workflow_runs WHERE status='completed')" 2>/dev/null)" 2>/dev/null || echo 0)
TOTAL_FAILED=$(printf '%d' "$(sqlite3 "$DB" "SELECT COUNT(*) FROM (SELECT id FROM issue_runs WHERE status='failed' UNION ALL SELECT id FROM pr_fix_runs WHERE status='failed' UNION ALL SELECT id FROM workflow_runs WHERE status='failed')" 2>/dev/null)" 2>/dev/null || echo 0)
TOTAL_RUNNING=$(printf '%d' "$(sqlite3 "$DB" "SELECT COUNT(*) FROM (SELECT id FROM issue_runs WHERE status='running' UNION ALL SELECT id FROM pr_fix_runs WHERE status='running' UNION ALL SELECT id FROM workflow_runs WHERE status='running')" 2>/dev/null)" 2>/dev/null || echo 0)
TOTAL_PENDING=$(printf '%d' "$(sqlite3 "$DB" "SELECT COUNT(*) FROM (SELECT id FROM issue_runs WHERE status IN ('pending','clarifying') UNION ALL SELECT id FROM pr_fix_runs WHERE status='pending' UNION ALL SELECT id FROM workflow_runs WHERE status='pending')" 2>/dev/null)" 2>/dev/null || echo 0)
TMUX_SESSIONS=$(tmux ls 2>/dev/null | grep -cE '^claude-' || true)
TMUX_SESSIONS=${TMUX_SESSIONS:-0}

# Build JSON with jq for safety
jq -n \
  --arg updated "$NOW" \
  --arg timer "$TIMER_ACTIVE" \
  --arg next_run "$NEXT_RUN" \
  --argjson running "$RUNNING" \
  --argjson pending "$PENDING" \
  --argjson recent "$RECENT" \
  --argjson events "$EVENTS" \
  --argjson stat_running "$TOTAL_RUNNING" \
  --argjson stat_pending "$TOTAL_PENDING" \
  --argjson stat_completed "$TOTAL_COMPLETED" \
  --argjson stat_failed "$TOTAL_FAILED" \
  --argjson tmux "$TMUX_SESSIONS" \
  '{
    updated: $updated,
    service: { timer: $timer, next_run: $next_run },
    stats: { running: $stat_running, pending: $stat_pending, completed: $stat_completed, failed: $stat_failed, tmux_sessions: $tmux },
    running: $running,
    pending: $pending,
    recent: $recent,
    events: $events
  }' > "$SCRIPT_DIR/data/state.json"

echo "Generated data/state.json"

# Commit & push if in a git repo with changes
cd "$SCRIPT_DIR"
if git rev-parse --is-inside-work-tree &>/dev/null; then
  if ! git diff --quiet data/state.json 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard data/state.json)" ]; then
    git add data/state.json
    git commit -m "update dashboard state"
    git push
    echo "Pushed to GitHub. Dashboard will update shortly."
  else
    echo "No changes to push."
  fi
fi
