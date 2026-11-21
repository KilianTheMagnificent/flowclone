#!/bin/bash
# End-to-end offline acceptance: synthetic voices, virtual calendar/hardware,
# real audio writer, local speech recognition, summarization, storage and hidden UI.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/work/meeting-mock-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$output"
output=$(cd "$output" && pwd)
export HANDSFREE_SESSION="flowclone-meeting-$$"
export FLOWCLONE_BUILD_ROOT="${FLOWCLONE_BUILD_ROOT:-$PWD}"
trap 'node tools/handsfree.mjs stop >/dev/null 2>&1 || true' EXIT
say -v Samantha -r 165 -o "$output/alex.aiff" 'This is Alex. We need to decide the pilot launch date. The onboarding checklist is ready, but the payment tests are still blocked. I propose launching the pilot on Friday with ten customers. We should not launch to everyone yet. Maya, can you send the checklist by Thursday?'
say -v Daniel -r 160 -o "$output/maya.aiff" 'This is Maya. Agreed, we will launch the pilot on Friday with ten customers. I will send the checklist by Thursday. Alex will finish the payment tests by Wednesday. The budget remains two thousand dollars. We still need to decide who will handle weekend support. Let us review the test results at our next meeting.'
tools/handsfree-flowclone.sh --with-model -- -appearanceTheme classic
payload=$(python3 - "$output" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
print(json.dumps({'audio':[str(p/'alex.aiff'),str(p/'maya.aiff')], 'output':str(p/'result')}))
PY
)
node tools/handsfree.mjs action meeting-mock "$payload"
for ((attempt=0; attempt<150; attempt++)); do
  result=$(node tools/handsfree.mjs action meeting-result)
  case "$result" in
    *PASS:*) printf '%s\n' "$result" | tee "$output/result.txt"; break ;;
    *FAIL:*) printf '%s\n' "$result" >&2; exit 1 ;;
  esac
  if (( attempt % 10 == 0 )); then printf '%s\n' "$result"; fi
  sleep 2
done
[[ "$result" == *PASS:* ]] || { echo "Mock did not complete within five minutes" >&2; exit 1; }
python3 - "$output/result" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
note=json.loads(next((root/'Meetings').glob('*/note.json')).read_text())
transcript=' '.join(s.get('text','') for s in note['segments']).lower()
summary=note['summary'].lower()
assert note['phase']=='complete'
assert {'microphone','system'}=={s['source'] for s in note['segments']}
for word in ('pilot','friday','checklist','thursday','payment','wednesday','weekend'):
    assert word in transcript, f'missing transcript detail: {word}'
for word in ('pilot','friday','checklist','thursday','wednesday','weekend'):
    assert word in summary, f'missing summary detail: {word}'
assert len(summary.split()) <= 240, 'summary is not concise'
assert 'keep these personal notes' in note['personalNotes'].lower()
assert 'keep these personal notes' not in summary
print('Content checks PASS: decisions, owners/deadlines, unresolved support, separate notes, concise summary')
PY
node tools/handsfree.mjs shot "$output/summary.png" --target FlowClone
node tools/handsfree.mjs click Transcript --target FlowClone
node tools/handsfree.mjs shot "$output/transcript.png" --target FlowClone
node tools/handsfree.mjs text --target FlowClone > "$output/accessibility.txt"
node tools/handsfree.mjs focus
node tools/handsfree.mjs logs --lines 100 > "$output/app-log.txt"
printf 'Mock evidence: %s\n' "$output"
