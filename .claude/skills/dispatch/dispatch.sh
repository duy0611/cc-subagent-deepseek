#!/usr/bin/env bash
# dispatch.sh: herdr helper for delegating tasks to worker agents (OpenCode/DeepSeek or Claude).
# Encodes the H0 lessons: --standalone OpenCode, per-pane default_agent, settle re-checks,
# target agents by name only, result.json as the completion signal.
#
# Usage:
#   dispatch.sh start   <id> <repo> [--kind opencode|claude] [--model M] [--base REF]
#   dispatch.sh prompt  <id> [text]     # default text: "Read and execute .delegate/<id>/brief.md"
#   dispatch.sh wait    <id> [timeout_s]
#   dispatch.sh status  <id>
#   dispatch.sh read    <id> [lines]
#   dispatch.sh approve <id> | reject <id>
#   dispatch.sh integrate <id> <commit message>   # commit worker changes + ff-merge into repo HEAD
#   dispatch.sh finish  <id> [--keep-branch|--discard]
#
# Env: HERDR_SESSION (named session; default: current session from HERDR_SOCKET_PATH, else "default")
#      DISPATCH_SETTLE_S (default 5)
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
SETTLE_S="${DISPATCH_SETTLE_S:-5}"
STATE_ROOT="${DISPATCH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dispatch}"

die() { jq -nc --arg e "$*" '{error:$e}' >&2; exit 1; }
# One JSON line for the PM: emit <id> <state> [key value]...
emit() {
  local id="$1" state="$2"; shift 2
  local args=(--arg id "$id" --arg state "$state") expr="{id:\$id,state:\$state"
  while [[ $# -gt 1 ]]; do args+=(--arg "$1" "$2"); expr+=",$1:\$$1"; shift 2; done
  jq -nc "${args[@]}" "$expr}"
}
h() {
  if [[ -n "${HERDR_SESSION:-}" ]]; then herdr --session "$HERDR_SESSION" "$@"; else herdr "$@"; fi
}
state_file() { echo "$STATE_ROOT/$1.json"; }
st() { jq -r "$2" "$(state_file "$1")"; }
agent_status() { h agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // "missing"'; }

cmd_start() {
  local id="$1" repo="$2"; shift 2
  local kind=opencode model="" base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      *) die "unknown flag $1" ;;
    esac
  done
  [[ "$id" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "id must match [a-z][a-z0-9_-]{0,31}"
  [[ -f "$(state_file "$id")" ]] && die "task $id already exists; finish it first"
  repo="$(cd "$repo" && git rev-parse --show-toplevel)"

  # 1. worktree (herdr opens it as its own workspace)
  local wt_args=(--cwd "$repo" --branch "ds/$id" --label "$id" --no-focus)
  [[ -n "$base" ]] && wt_args+=(--base "$base")
  local wt; wt="$(h worktree create "${wt_args[@]}")"
  local ws path root
  ws="$(jq -r '.result.workspace.workspace_id' <<<"$wt")"
  path="$(jq -r '.result.workspace.worktree.checkout_path' <<<"$wt")"
  root="$(jq -r '.result.root_pane.pane_id' <<<"$wt")"
  mkdir -p "$path/.delegate/$id"

  # 2. worker pane in the checkout, with per-pane agent selection
  local split_args=("$root" --direction right --cwd "$path" --no-focus)
  [[ "$kind" == opencode ]] && split_args+=(--env 'OPENCODE_CONFIG_CONTENT={"default_agent":"worker"}')
  local pane; pane="$(h pane split "${split_args[@]}" | jq -r '.result.pane.pane_id')"
  sleep 1

  # 3. agent
  local agent_args=()
  case "$kind" in
    opencode) agent_args=(-- --standalone); [[ -n "$model" ]] && agent_args+=(-m "$model") ;;
    claude)   agent_args=(-- --permission-mode acceptEdits); [[ -n "$model" ]] && agent_args+=(--model "$model") ;;
    *) die "unsupported kind $kind" ;;
  esac
  local out; out="$(h agent start "$id" --kind "$kind" --pane "$pane" --timeout 90000 "${agent_args[@]}" 2>&1)" || true

  mkdir -p "$STATE_ROOT"
  jq -n --arg id "$id" --arg repo "$repo" --arg path "$path" --arg ws "$ws" --arg pane "$pane" \
        --arg kind "$kind" --arg model "$model" --arg branch "ds/$id" \
        '{id:$id,repo:$repo,worktree:$path,branch:$branch,workspace:$ws,pane:$pane,kind:$kind,model:$model}' \
        > "$(state_file "$id")"
  jq -c --arg s "$(agent_status "$id")" '. + {agent_status:$s}' "$(state_file "$id")"
  if [[ "$(agent_status "$id")" == missing ]]; then
    echo "WARN: agent not detected yet (startup dialog?). Inspect with: dispatch.sh read $id" >&2
    echo "$out" | tail -c 400 >&2
  fi
}

cmd_prompt() {
  local id="$1"; shift
  local text="${*:-Read and execute .delegate/$id/brief.md}"
  local s; s="$(agent_status "$id")"
  [[ "$s" == idle || "$s" == done ]] || die "agent $id is $s; only prompt idle/done agents (read it first)"
  h agent prompt "$id" "$text" | jq -c '{submitted: (.result != null), error: .error}'
}

# Wait until the task is really finished: settled idle/done that holds across a re-check
# AND result.json exists, or a blocked state that needs a PM decision.
cmd_wait() {
  local id="$1" timeout_s="${2:-1800}"
  local result; result="$(st "$id" .worktree)/.delegate/$id/result.json"
  local deadline=$(( $(date +%s) + timeout_s )) idle_no_result=0
  while (( $(date +%s) < deadline )); do
    local left=$(( (deadline - $(date +%s)) * 1000 ))
    (( left < 3001 )) && break
    h agent wait "$id" --until idle --until done --until blocked --timeout "$left" >/dev/null 2>&1 || true
    sleep "$SETTLE_S"
    local s; s="$(agent_status "$id")"
    case "$s" in
      blocked) emit "$id" blocked; return 0 ;;
      missing) emit "$id" agent_gone; return 1 ;;
      idle|done)
        if [[ -f "$result" ]]; then
          jq -c --arg id "$id" '{id:$id,state:"finished",result:.}' "$result"; return 0
        fi
        # settled without result.json: give the worker two more settle rounds, then report
        if (( ++idle_no_result >= 3 )); then
          emit "$id" idle_without_result; return 0
        fi ;;
      *) idle_no_result=0 ;;
    esac
  done
  emit "$id" timeout agent_status "$(agent_status "$id")"
}

cmd_status() {
  local id="$1" wt; wt="$(st "$id" .worktree)"
  jq -c --arg s "$(agent_status "$id")" \
        --arg diff "$(git -C "$wt" status --short | head -30)" \
        --argjson has_result "$([[ -f "$wt/.delegate/$id/result.json" ]] && echo true || echo false)" \
        '. + {agent_status:$s, has_result:$has_result, changes:$diff}' "$(state_file "$id")"
}

# Scrollback reads only work while idle; fall back to the visible screen (e.g. when blocked).
cmd_read() {
  local out
  out="$(h agent read "$1" --source recent-unwrapped --lines "${2:-60}" 2>/dev/null)" \
    || out="$(h agent read "$1" --source visible)"
  grep -v '^[[:space:]┃]*$' <<<"$out" || true
}
cmd_approve() { h agent send-keys "$1" enter | jq -c '.result.type // .'; }
cmd_reject()  { h agent send-keys "$1" esc   | jq -c '.result.type // .'; }

# Commit the worker's changes on its branch (PM authors the commit) and fast-forward the repo's
# current branch to it. .delegate/ is git-ignored, so `add -A` never picks it up.
cmd_integrate() {
  local id="$1"; shift
  local msg="${*:-}"
  [[ -n "$msg" ]] || die "usage: integrate <id> <commit message>"
  local wt repo branch; wt="$(st "$id" .worktree)"; repo="$(st "$id" .repo)"; branch="$(st "$id" .branch)"
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet; then
    die "no changes to integrate in $wt"
  fi
  git -C "$wt" commit -q -m "$msg"
  git -C "$repo" merge --ff-only -q "$branch" || die "fast-forward failed; rebase $branch or merge manually"
  jq -nc --arg id "$id" --arg commit "$(git -C "$repo" rev-parse --short HEAD)" '{id:$id,integrated:true,commit:$commit}'
}

# Stop the agent and remove the worktree. Refuses to discard work: uncommitted changes or commits
# not merged into the repo's HEAD require --discard (or --keep-branch to keep the commits).
cmd_finish() {
  local id="$1" flag="${2:-}"
  [[ -f "$(state_file "$id")" ]] || die "unknown task $id"
  local ws repo branch wt
  ws="$(st "$id" .workspace)"; repo="$(st "$id" .repo)"; branch="$(st "$id" .branch)"; wt="$(st "$id" .worktree)"
  if [[ "$flag" != --discard && -d "$wt" && -n "$(git -C "$wt" status --porcelain)" ]]; then
    die "worktree $wt has uncommitted changes; run integrate first, or finish $id --discard"
  fi
  local merged=false
  git -C "$repo" merge-base --is-ancestor "$branch" HEAD 2>/dev/null && merged=true
  if [[ "$flag" != --discard && "$flag" != --keep-branch && "$merged" == false ]]; then
    die "$branch has commits not merged into HEAD; integrate, or finish $id --keep-branch|--discard"
  fi
  h agent send-keys "$id" ctrl+c >/dev/null 2>&1 || true
  sleep 1
  h worktree remove --workspace "$ws" --force >/dev/null 2>&1 || git -C "$repo" worktree remove --force "$wt"
  if [[ "$flag" != --keep-branch ]]; then
    git -C "$repo" branch -D "$branch" -q 2>/dev/null || true
  fi
  rm -f "$(state_file "$id")"
  jq -nc --arg id "$id" --arg flag "$flag" '{id:$id,finished:true,flag:$flag}'
}

sub="${1:-}"; shift || true
case "$sub" in
  start|prompt|wait|status|read|approve|reject|integrate|finish) "cmd_$sub" "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
