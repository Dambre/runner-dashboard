#!/usr/bin/env bash
# Query runner DB → generate data/state.json → commit & push to GitHub Pages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${SCRIPT_DIR}/../tasku/.db/runner.db"
TASKU_DB="${SCRIPT_DIR}/../tasku/.db/tasku.db"

if [ ! -f "$DB" ]; then
  echo "Error: runner.db not found at $DB" >&2
  exit 1
fi

# sqlite3 -json returns "" for empty results; normalize to "[]"
q() {
  local result
  result=$(sqlite3 -json "$DB" "ATTACH '$TASKU_DB' AS tasku; $1" 2>/dev/null) || true
  if [ -z "$result" ]; then echo "[]"; else echo "$result"; fi
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Service status
TIMER_ACTIVE=$(systemctl --user is-active claude-runner.timer 2>/dev/null || echo "inactive")
NEXT_RUN=$(systemctl --user show claude-runner.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")

# GitHub base URL
GH="https://github.com"
# Workflow repo for workflow issue URLs
WF_REPO="Dambre/claude-tasku-workflow"

# Running sessions
RUNNING=$(q "
  SELECT type, repo, ref, url, phase, started_at, duration FROM (
    SELECT 'issue' as type, r.name as repo, '#'||i.issue_number as ref,
      '$GH/'||r.fork||'/issues/'||i.issue_number as url,
      COALESCE(ds.phase_name, '') as phase,
      i.started_at,
      CAST((julianday('now') - julianday(i.started_at)) * 24 AS INT) || 'h ' ||
      CAST(((julianday('now') - julianday(i.started_at)) * 1440) % 60 AS INT) || 'm' as duration
    FROM issue_runs i
    JOIN repos r ON i.repo_id=r.id
    LEFT JOIN tasku.develop_sessions ds ON ds.slug LIKE 'issue-'||i.issue_number||'-%' AND ds.active=1
    WHERE i.status='running'
    UNION ALL
    SELECT 'pr_fix', r.name, 'PR#'||p.pr_number,
      '$GH/'||r.fork||'/pull/'||p.pr_number,
      COALESCE(ds.phase_name, '') as phase,
      p.started_at,
      CAST((julianday('now') - julianday(p.started_at)) * 24 AS INT) || 'h ' ||
      CAST(((julianday('now') - julianday(p.started_at)) * 1440) % 60 AS INT) || 'm' as duration
    FROM pr_fix_runs p
    JOIN repos r ON p.repo_id=r.id
    LEFT JOIN tasku.develop_sessions ds ON ds.slug=p.branch_name AND ds.active=1
    WHERE p.status='running'
    UNION ALL
    SELECT 'workflow', 'workflow', '#'||w.issue_number,
      '$GH/$WF_REPO/issues/'||w.issue_number,
      COALESCE(ds.phase_name, '') as phase,
      w.started_at,
      CAST((julianday('now') - julianday(w.started_at)) * 24 AS INT) || 'h ' ||
      CAST(((julianday('now') - julianday(w.started_at)) * 1440) % 60 AS INT) || 'm' as duration
    FROM workflow_runs w
    LEFT JOIN tasku.develop_sessions ds ON ds.slug LIKE 'workflow-'||w.issue_number||'-%' AND ds.active=1
    WHERE w.status='running'
  ) ORDER BY started_at
")

# Pending / clarifying
PENDING=$(q "
  SELECT type, repo, ref, url, status, created_at FROM (
    SELECT 'issue' as type, r.name as repo, '#'||i.issue_number as ref,
      '$GH/'||r.fork||'/issues/'||i.issue_number as url, i.status, i.created_at
    FROM issue_runs i JOIN repos r ON i.repo_id=r.id WHERE i.status IN ('pending','clarifying')
    UNION ALL
    SELECT 'pr_fix', r.name, 'PR#'||p.pr_number,
      '$GH/'||r.fork||'/pull/'||p.pr_number, p.status, p.created_at
    FROM pr_fix_runs p JOIN repos r ON p.repo_id=r.id WHERE p.status='pending'
    UNION ALL
    SELECT 'workflow', 'workflow', '#'||issue_number,
      '$GH/$WF_REPO/issues/'||issue_number, status, created_at
    FROM workflow_runs WHERE status='pending'
  ) ORDER BY created_at
")

# Recent completed/failed
RECENT=$(q "
  SELECT type, repo, ref, url, pr_url, status, completed_at, error_message FROM (
    SELECT 'issue' as type, r.name as repo, '#'||i.issue_number as ref,
      '$GH/'||r.fork||'/issues/'||i.issue_number as url,
      CASE WHEN i.pr_number IS NOT NULL THEN '$GH/'||r.fork||'/pull/'||i.pr_number ELSE NULL END as pr_url,
      i.status, i.completed_at,
      CASE WHEN INSTR(i.error_message, CHAR(10)) > 0 THEN SUBSTR(i.error_message, 1, INSTR(i.error_message, CHAR(10)) - 1) ELSE i.error_message END as error_message
    FROM issue_runs i JOIN repos r ON i.repo_id=r.id WHERE i.status IN ('completed','failed')
    UNION ALL
    SELECT 'pr_fix', r.name, 'PR#'||p.pr_number,
      '$GH/'||r.fork||'/pull/'||p.pr_number, NULL,
      p.status, p.completed_at,
      CASE WHEN INSTR(p.error_message, CHAR(10)) > 0 THEN SUBSTR(p.error_message, 1, INSTR(p.error_message, CHAR(10)) - 1) ELSE p.error_message END as error_message
    FROM pr_fix_runs p JOIN repos r ON p.repo_id=r.id WHERE p.status IN ('completed','failed')
    UNION ALL
    SELECT 'workflow', 'workflow', '#'||issue_number,
      '$GH/$WF_REPO/issues/'||issue_number,
      CASE WHEN pr_number IS NOT NULL THEN '$GH/$WF_REPO/pull/'||pr_number ELSE NULL END,
      status, completed_at,
      CASE WHEN INSTR(error_message, CHAR(10)) > 0 THEN SUBSTR(error_message, 1, INSTR(error_message, CHAR(10)) - 1) ELSE error_message END as error_message
    FROM workflow_runs WHERE status IN ('completed','failed')
  ) ORDER BY completed_at DESC LIMIT 10
")

# Last events — sanitize messages to avoid leaking file paths, hashes, etc.
# Only keep first line, strip anything after ' — ' (git output), and cap length
EVENTS=$(q "
  SELECT run_type, event,
    CASE
      WHEN INSTR(message, ' — ') > 0 THEN SUBSTR(message, 1, INSTR(message, ' — ') - 1)
      WHEN INSTR(message, CHAR(10)) > 0 THEN SUBSTR(message, 1, INSTR(message, CHAR(10)) - 1)
      ELSE message
    END as message,
    created_at
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
    git commit --amend --no-edit
    git push --force-with-lease
    echo "Pushed to GitHub. Dashboard will update shortly."
  else
    echo "No changes to push."
  fi
fi
