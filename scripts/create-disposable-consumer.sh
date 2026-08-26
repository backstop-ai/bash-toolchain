#!/usr/bin/env bash
set -euo pipefail

if (( $# != 7 )); then
  printf 'usage: %s <mode> <mutation> <commit> <tree> <digest> <function-file> <staged-pack>\n' "$0" >&2
  exit 64
fi
mode=$1
mutation=$2
candidate_commit=$3
candidate_tree=$4
candidate_digest=$5
function_file=$6
staged_pack=$7
case "$mode" in
  manifest-contract|execution-contract) ;;
  *) printf 'bash-toolchain: unknown consumer mode %s\n' "$mode" >&2; exit 64 ;;
esac
case "$mutation" in
  none|missing-bash|missing-verifier|failing-verifier|producer-failure|converter-failure|malformed-converter-output) ;;
  *) printf 'bash-toolchain: unknown mutation %s\n' "$mutation" >&2; exit 64 ;;
esac
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ && "$candidate_tree" =~ ^[0-9a-f]{40}$ && "$candidate_digest" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'bash-toolchain: malformed candidate identity\n' >&2; exit 65;
}
[[ -f "$function_file" && -d "$staged_pack" && -f "$staged_pack/pack.yml" ]] || {
  printf 'bash-toolchain: missing function data or staged candidate\n' >&2; exit 65;
}
function_file=$(cd "$(dirname "$function_file")" && pwd)/$(basename "$function_file")
staged_pack=$(cd "$staged_pack" && pwd)
if [[ -e "$staged_pack/.git" || -e "$staged_pack/.backstop" ]]; then
  printf 'bash-toolchain: staged candidate contains forbidden metadata\n' >&2
  exit 65
fi
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$staged_pack" in "$repo_root"|"$repo_root"/*) printf 'bash-toolchain: live repository path rejected\n' >&2; exit 65;; esac

mapfile -t functions < "$function_file"
(( ${#functions[@]} > 0 )) || { printf 'bash-toolchain: empty function set\n' >&2; exit 65; }
declare -A seen=()
for function_name in "${functions[@]}"; do
  [[ "$function_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'bash-toolchain: malformed function name\n' >&2; exit 65; }
  [[ -z "${seen[$function_name]+x}" ]] || { printf 'bash-toolchain: duplicate function name\n' >&2; exit 65; }
  seen[$function_name]=1
done

consumer=$(mktemp -d /tmp/backstop-bash-consumer.XXXXXX)
negative_consumer=''
cleanup() {
  rm -rf -- "$consumer"
  if [[ -n "$negative_consumer" ]]; then rm -rf -- "$negative_consumer"; fi
}
trap cleanup EXIT HUP INT TERM
printf 'consumer_path=%s\n' "$consumer"
backstop_bin=${BACKSTOP_BIN:-backstop}
cd "$consumer"
git init -q
git config user.email fixture@backstop.sh
git config user.name 'Backstop Fixture'
printf '# Bash toolchain consumer\n' > README.md
git add README.md
git commit -qm init

"$backstop_bin" artifact new bundle --slug bash-toolchain-consumer >/dev/null
"$backstop_bin" artifact new spec --slug bash-toolchain-consumer >/dev/null
"$backstop_bin" artifact new plan --source SPEC-001 --slug bash-toolchain-consumer >/dev/null

python3 - "$consumer" "$mode" "$function_file" <<'PY'
import datetime,pathlib,sys,yaml
root=pathlib.Path(sys.argv[1]); mode=sys.argv[2]
funcs=[x.strip() for x in pathlib.Path(sys.argv[3]).read_text().splitlines() if x.strip()]
date=datetime.date.today().isoformat()
bundle={
 'title':'Bash Toolchain Consumer','number':'BUNDLE-001','created':date,'schema_version':'bundle/v2',
 'bundle':{'name':'bash-toolchain-consumer','version':'0.1.0','created':date,'category':'tool'},
 'status':{'maturity':'exploring'},
 'problem':{'summary':'Validate a staged Bash toolchain candidate in a complete disposable artifact consumer.','user_story':'As a pack author, I need assembled-gate evidence from a valid consumer.'},
 'requirements':[{'id':f'REQ-{i:03d}','version':'1.0.0','text':f'The consumer must discover and execute {name}.','versions':[{'version':'1.0.0','text':f'The consumer must discover and execute {name}.'}]} for i,name in enumerate(funcs,1)],
 'spec_seeds':[{'id':'SPEC-001','owns':[f'REQ-{i:03d}' for i in range(1,len(funcs)+1)]}],
}
spec={
 'title':'SPEC-001: Bash Toolchain Consumer','number':'SPEC-001','created':date,'status':'draft','schema_version':'spec/v1','spec_version':'1.0.0',
 'implementation':{'summary':f'Exercise the {mode} Bash toolchain fixture.','subject':'scripts/verify-public-product-model.sh'},
 'verification':{'level':'build','test_command':'./scripts/verify-public-product-model.sh'},
 'requirements':[{'id':f'REQ-{i:03d}','supports':[f'bash-toolchain-consumer:REQ-{i:03d}@1.0.0'],'text':f'Discover and execute {name}.'} for i,name in enumerate(funcs,1)],
 'claims':[{'id':f'CLM-{i:03d}','requirement':f'REQ-{i:03d}','text':f'{name} is discovered and green.','tests':[name]} for i,name in enumerate(funcs,1)],
 'contracts':[{'file':'scripts/verify-public-product-model.sh','provides':[{'name':'canonical_verifier','kind':'function','signature':'canonical_verifier()'}]}],
}
claims=[f'CLM-{i:03d}' for i in range(1,len(funcs)+1)]
plan={
 'plan_id':'PLAN-SPEC-001','spec_id':'SPEC-001','spec_version':'1.0.0','created':date,'status':'draft','target_repo':'disposable-consumer','test_command':'./scripts/verify-public-product-model.sh',
 'phases':[{'id':'phase-1','name':'Consumer acceptance','tasks':[
   {'id':'TASK-001','type':'test','title':'Declare mandated tests','description':'Install the selected fixture tests before implementation.','files':['scripts/tests/consumer/selected.sh'],'claims':claims,'test_names':funcs,'depends_on':[]},
   {'id':'TASK-002','type':'implementation','title':'Install canonical verifier','description':'Install the canonical verifier and selected fixtures.','files':['scripts/verify-public-product-model.sh'],'claims':claims,'depends_on':['TASK-001']},
   {'id':'TASK-003','type':'verification','title':'Run assembled gate','description':'Run the complete assembled Backstop gate.','files':['scripts/verify-public-product-model.sh','scripts/tests/consumer/selected.sh'],'claims':claims,'depends_on':['TASK-002']},
 ]}],
}
def md(path,data,sections):
 path.write_text('---\n'+yaml.safe_dump(data,sort_keys=False)+'---\n\n# '+data['title']+'\n\n'+''.join(f'## {s}\n\nFixture acceptance.\n\n' for s in sections))
md(root/'bundles/BUNDLE-001-bash-toolchain-consumer.bundle.md',bundle,['Current Thinking','Spec Seeds'])
md(root/'specs/SPEC-001-bash-toolchain-consumer.spec.md',spec,['Overview','Requirements','Implementation','Verification'])
(root/'plans/PLAN-SPEC-001-bash-toolchain-consumer.plan.yml').write_text('---\n'+yaml.safe_dump(plan,sort_keys=False)+'---\n')
PY

mkdir -p scripts/tests/consumer testdata
cp "$repo_root/scripts/verify-public-product-model.sh" scripts/verify-public-product-model.sh
cp "$staged_pack/pack.yml" pack.yml
case "$mode" in
  manifest-contract)
    cp "$repo_root/scripts/tests/bash-toolchain/manifest-contract.sh" scripts/tests/consumer/selected.sh
    mkdir -p testdata/classification testdata/name-patterns
    cp "$repo_root/testdata/classification/path-matrix.txt" testdata/classification/path-matrix.txt
    cp "$repo_root/testdata/name-patterns/positive.txt" testdata/name-patterns/positive.txt
    cp "$repo_root/testdata/name-patterns/negative.txt" testdata/name-patterns/negative.txt
    ;;
  execution-contract)
    cp "$repo_root/scripts/tests/bash-toolchain/execution-contract.sh" scripts/tests/consumer/selected.sh
    mkdir -p scripts/tests/bash-toolchain
    cp "$repo_root/scripts/tests/bash-toolchain/execution-contract.sh" scripts/tests/bash-toolchain/execution-contract.sh
    cp -R "$repo_root/testdata/execution" testdata/execution
    mkdir -p testdata/consumer/harness
    cp "$repo_root/testdata/consumer/harness/execution-functions.txt" testdata/consumer/harness/execution-functions.txt
    cp "$repo_root/scripts/create-disposable-consumer.sh" scripts/create-disposable-consumer.sh
    cp "$repo_root/scripts/test-produce.sh" scripts/test-produce.sh
    cp "$repo_root/scripts/test-to-sarif.sh" scripts/test-to-sarif.sh
    cp "$repo_root/scripts/stage-local-candidate.sh" scripts/stage-local-candidate.sh
    ;;
esac

printf 'project: bash-toolchain-consumer\npacks: {}\n' > backstop.yml
"$backstop_bin" artifact validate --all >/tmp/backstop-bash-artifact-validation.log
printf 'artifact_validation=pass\n'

pack_byte_mutation=false
case "$mutation" in producer-failure|converter-failure|malformed-converter-output) pack_byte_mutation=true;; esac
if [[ "$pack_byte_mutation" == true ]]; then
  negative_consumer=$(mktemp -d /tmp/backstop-bash-negative.XXXXXX)
  cp -R "$consumer/." "$negative_consumer/"
  [[ ! -e "$negative_consumer/backstop.lock" && ! -d "$negative_consumer/.backstop/packs/backstop-ai/bash-toolchain" ]] || {
    printf 'bash-toolchain: negative consumer was not fresh before first install\n' >&2; exit 65;
  }
  if grep -q 'backstop-ai/bash-toolchain' "$negative_consumer/backstop.yml"; then
    printf 'bash-toolchain: negative consumer already declares bash-toolchain\n' >&2; exit 65
  fi
fi

"$backstop_bin" pack add "$staged_pack" --version 0.1.0 >/dev/null
locked_digest=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' backstop.lock)
[[ "$locked_digest" == "$candidate_digest" ]] || { printf 'bash-toolchain: candidate digest mismatch %s\n' "$locked_digest" >&2; exit 65; }
if find .backstop/packs/backstop-ai/bash-toolchain -type d -name .backstop -print -quit | grep -q .; then
  printf 'bash-toolchain: nested .backstop in installed candidate\n' >&2; exit 65
fi
printf 'candidate_commit=%s\ncandidate_tree=%s\ncandidate_digest=%s\ncandidate_identity=pass\n' "$candidate_commit" "$candidate_tree" "$candidate_digest"
printf 'external_sandbox_opt_out=true\n'

gate_root=$consumer
gate_path=$PATH
expected_pattern=''
expected_class=''
case "$mutation" in
  none) ;;
  missing-bash)
    gate_path=$(mktemp -d "$consumer/no-bash.XXXXXX")
    expected_pattern='bash|executable|producer'
    expected_class='tool_absence'
    ;;
  missing-verifier)
    target=$(realpath -m "$consumer/scripts/verify-public-product-model.sh")
    [[ "$target" == "$consumer"/* ]] || exit 65
    rm -f -- "$target"
    expected_pattern='verify-public-product-model|No such file|producer'
    expected_class='canonical_verifier_absent'
    ;;
  failing-verifier)
    target=$(realpath -m "$consumer/scripts/verify-public-product-model.sh")
    [[ "$target" == "$consumer"/* ]] || exit 65
    cp "$repo_root/testdata/execution/fail/scripts/verify-public-product-model.sh" "$target"
    expected_pattern='deliberate failure|bash-test'
    expected_class='canonical_verifier_nonzero'
    ;;
  producer-failure|converter-failure|malformed-converter-output)
    gate_root=$negative_consumer
    negative_pack="$negative_consumer/negative-pack"
    cp -R "$staged_pack" "$negative_pack"
    [[ "$negative_pack" == "$negative_consumer"/* && ! -e "$negative_pack/.backstop" ]] || exit 65
    case "$mutation" in
      producer-failure)
        printf '#!/usr/bin/env bash\nprintf "deterministic producer crash\\nBACKSTOP_BASH_TEST_EXIT_STATUS=71\\n"\nexit 71\n' > "$negative_pack/scripts/test-produce.sh"
        chmod +x "$negative_pack/scripts/test-produce.sh"
        expected_pattern='crashed|producer|deterministic producer crash'
        expected_class='producer_crash'
        ;;
      converter-failure)
        printf '#!/usr/bin/env bash\nprintf "deterministic converter crash\\n" >&2\nexit 72\n' > "$negative_pack/scripts/test-to-sarif.sh"
        chmod +x "$negative_pack/scripts/test-to-sarif.sh"
        expected_pattern='convert step|converter crash'
        expected_class='converter_crash'
        ;;
      malformed-converter-output)
        printf '#!/usr/bin/env bash\nprintf "deterministic malformed output\\n"\n' > "$negative_pack/scripts/test-to-sarif.sh"
        chmod +x "$negative_pack/scripts/test-to-sarif.sh"
        expected_pattern='SARIF|sarif|malformed'
        expected_class='malformed_converter_output'
        ;;
    esac
    cd "$negative_consumer"
    "$backstop_bin" artifact validate --all >/dev/null
    "$backstop_bin" pack add "$negative_pack" --version 0.1.0 >/dev/null
    negative_digest=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' backstop.lock)
    [[ -n "$negative_digest" && "$negative_digest" != "$candidate_digest" ]] || { printf 'bash-toolchain: negative digest was absent or unchanged\n' >&2; exit 65; }
    printf 'negative_first_install=true\nnegative_digest=%s\n' "$negative_digest"
    ;;
esac

cd "$gate_root"
gate_report="$gate_root/backstop-gate.json"
gate_stderr="$gate_root/backstop-gate.stderr"
set +e
PATH="$gate_path" BACKSTOP_PACK_SANDBOX=external \
  BACKSTOP_BIN="$backstop_bin" \
  BACKSTOP_EXECUTION_MATRIX_STAGE="$staged_pack" \
  BACKSTOP_EXECUTION_MATRIX_COMMIT="$candidate_commit" \
  BACKSTOP_EXECUTION_MATRIX_TREE="$candidate_tree" \
  BACKSTOP_EXECUTION_MATRIX_DIGEST="$candidate_digest" \
  BACKSTOP_EXECUTION_MATRIX_FUNCTION_FILE="$consumer/testdata/consumer/harness/execution-functions.txt" \
  "$backstop_bin" --json gate --all >"$gate_report" 2>"$gate_stderr"
gate_status=$?
set -e
python3 - "$gate_report" <<'PY' || { cat "$gate_stderr" >&2; cat "$gate_report" >&2; exit 1; }
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
step=next((s for s in data.get('steps',[]) if s.get('step_name')=='pack_lock_verification'),None)
if not step or step.get('status')!='pass' or step.get('violations'): raise SystemExit('pack lock verification did not pass before engine dispatch')
PY
printf 'pack_lock_verification=pass\nmutation=%s\ngate_status=%s\n' "$mutation" "$gate_status"
if [[ "$mutation" == none ]]; then
  [[ $gate_status -eq 0 ]] || { cat "$gate_stderr" >&2; cat "$gate_report" >&2; exit 1; }
  python3 - "$gate_report" <<'PY' || exit 1
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8')); steps={s['step_name']:s for s in data.get('steps',[])}
for name in ('pack_engines','test_verification'):
 step=steps.get(name)
 if not step or step.get('status')!='pass' or step.get('violations'): raise SystemExit(f'{name} did not pass cleanly')
PY
  printf 'gate_expected=pass\ngate_observed=pass\ndiscovery_count=%s\npack_engines=pass\ntest_verification=pass\n' "${#functions[@]}"
else
  [[ $gate_status -ne 0 ]] || { printf 'bash-toolchain: mutation unexpectedly passed\n' >&2; exit 1; }
  python3 - "$gate_report" "$mutation" "$expected_class" <<'PY' || { cat "$gate_stderr" >&2; cat "$gate_report" >&2; exit 1; }
import json,re,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
step=next((s for s in data.get('steps',[]) if s.get('step_name')=='pack_engines'),None)
if not step or step.get('status')!='fail': raise SystemExit('pack_engines was not the observed failing step')
violations=step.get('violations',[])
if not violations: raise SystemExit('pack_engines carried no structured violations')
evidence='\n'.join(f"{v.get('rule','')} {v.get('message','')} {v.get('path','')}" for v in violations)
classifiers=(
 ('tool_absence', r'required tool "bash" not found|never started.*bash'),
 ('canonical_verifier_absent', r'verify-public-product-model\.sh.*(?:no such file|producer|never started)'),
 ('canonical_verifier_nonzero', r'deliberate failure'),
 ('producer_crash', r'deterministic producer crash'),
 ('converter_crash', r'convert step \(scripts/test-to-sarif\.sh\) failed: exit status 72'),
 ('malformed_converter_output', r'(?:invalid|malformed|parse).*SARIF|SARIF.*(?:invalid|malformed|parse)'),
)
matched=[name for name,pattern in classifiers if re.search(pattern,evidence,re.I|re.S)]
if len(matched)!=1: raise SystemExit(f'mutation-specific structured evidence was ambiguous or absent ({matched}): {evidence}')
observed_class=matched[0]
if observed_class != sys.argv[3]: raise SystemExit(f'derived class {observed_class} differs from expected {sys.argv[3]}')
first=violations[0]
diagnostic=' '.join(str(first.get('message','')).split())
path=' '.join(str(first.get('path','')).split())
print('observed_step=pack_engines')
print('observed_rule='+str(first.get('rule','')))
print('observed_diagnostic='+diagnostic)
print('observed_path='+(path or 'none'))
print('observed_class='+observed_class)
PY
  printf 'gate_expected=fail\ngate_observed=fail\nexpected_diagnostic=%s\nexpected_class=%s\n' "$expected_pattern" "$expected_class"
fi
cleanup
trap - EXIT HUP INT TERM
printf 'consumer_cleanup=pass\n'
