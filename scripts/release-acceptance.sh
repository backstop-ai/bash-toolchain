#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
core_repo=${BACKSTOP_CORE_REPO:-/workspace/scratch/1d6aa3e9c498/backstop-core}
backstop_bin=${BACKSTOP_BIN:-$core_repo/bin/backstop}
candidate_commit=${BACKSTOP_CANDIDATE_COMMIT:-}
candidate_tree=${BACKSTOP_CANDIDATE_TREE:-}
candidate_digest=${BACKSTOP_CANDIDATE_DIGEST:-}
core_commit=2855ccd1438c455fc2a6842978c15e5cf582ff5b
core_tree=97a9480b579b8aac1f4fec8d8294c70aee56a232
required_core_fix=ca9241fd738cf76349e36f0bebfd2c208e8b132e

die() { printf 'bash-toolchain: %s\n' "$*" >&2; exit 65; }

require_candidate_identity() {
  if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ || ! "$candidate_tree" =~ ^[0-9a-f]{40}$ || ! "$candidate_digest" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'candidate_identity_recompute=required\n'
    printf 'candidate_identity_reason=accepted_pack_bytes_changed\n'
    exit 76
  fi
  [[ $(git -C "$repo_root" rev-parse "$candidate_commit^{commit}" 2>/dev/null) == "$candidate_commit" ]] || die 'candidate commit is unavailable locally'
  [[ $(git -C "$repo_root" rev-parse "$candidate_commit^{tree}" 2>/dev/null) == "$candidate_tree" ]] || die 'candidate tree does not match candidate commit'
}

require_core_binary() {
  [[ -x "$backstop_bin" ]] || die "Backstop binary is not executable: $backstop_bin"
  [[ -d "$core_repo/.git" ]] || die "Backstop Core checkout is unavailable: $core_repo"
  local binary_commit
  binary_commit=$("$backstop_bin" version | sed -n 's/^commit: //p')
  if [[ -z "$binary_commit" ]] || ! git -C "$core_repo" merge-base --is-ancestor "$required_core_fix" "$binary_commit" 2>/dev/null; then
    printf 'executable_acceptance=blocked\nrequired_core_commit=%s\nobserved_binary_commit=%s\n' \
      "$required_core_fix" "${binary_commit:-unknown}"
    printf 'bash-toolchain: released Backstop binary does not contain ISSUE-188\n' >&2
    exit 75
  fi
}

stage_callback() {
  local internal_mode=$1
  shift
  BACKSTOP_BIN="$backstop_bin" bash "$repo_root/scripts/stage-local-candidate.sh" \
    "$candidate_commit" "$candidate_tree" -- bash "$0" "$internal_mode" "$@"
}

make_core_fixture() {
  local destination=$1
  git clone -q --no-hardlinks "$core_repo" "$destination"
  git -C "$destination" checkout -q --detach "$core_commit"
  [[ $(git -C "$destination" rev-parse HEAD) == "$core_commit" ]] || die 'Core commit mismatch'
  [[ $(git -C "$destination" rev-parse 'HEAD^{tree}') == "$core_tree" ]] || die 'Core tree mismatch'
  [[ -z $(git -C "$destination" status --porcelain) ]] || die 'pinned Core fixture is dirty'
  mkdir -p "$destination/.backstop/packs"
  cp -R "$core_repo/.backstop/packs/." "$destination/.backstop/packs/"
}

install_candidate() {
  local consumer=$1 source=$2 source_kind=${3:-local}
  (
    cd "$consumer"
    if [[ "$source_kind" == remote ]]; then
      "$backstop_bin" pack add "$source" >/dev/null
    else
      "$backstop_bin" pack add "$source" --version 0.1.0 >/dev/null
    fi
    local locked source_type source_coordinate git_ref version
    locked=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' backstop.lock)
    [[ "$locked" == "$candidate_digest" ]] || die "candidate digest mismatch: $locked"
    source_type=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*source_type:[[:space:]]*//p' backstop.lock)
    source_coordinate=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*source_coordinate:[[:space:]]*//p' backstop.lock)
    git_ref=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*git_ref:[[:space:]]*//p' backstop.lock)
    version=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*version:[[:space:]]*//p' backstop.lock | tr -d '"')
    if [[ "$source_kind" == remote ]]; then
      [[ "$source_type" == git && "$source_coordinate" == backstop-ai/bash-toolchain && "$git_ref" == v0.1.0 && "$version" == 0.1.0 ]] || die "remote lock identity was $source_type/$source_coordinate/$git_ref/$version"
    else
      [[ "$source_type" == local ]] || die "local candidate unexpectedly locked as $source_type"
    fi
    ! find .backstop/packs/backstop-ai/bash-toolchain -type d -name .backstop -print -quit | grep -q . || die 'nested .backstop in installed candidate'
  )
}

establish_spec072_pack_profile() {
  local root=$1 source=$2 source_kind=${3:-local} pack
  local -a declared_packs=()
  mapfile -t declared_packs < <(python3 - "$root/backstop.yml" <<'PY'
import pathlib,sys,yaml
data=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
for name in (data.get('packs') or {}):
 print(name)
PY
  )
  for pack in "${declared_packs[@]}"; do
    (cd "$root"; "$backstop_bin" pack remove "$pack" >/dev/null)
  done
  install_candidate "$root" "$source" "$source_kind"
  assert_spec072_pack_profile "$root"
}

assert_spec072_pack_profile() {
  local root=$1 baseline=${2:-}
  if [[ -n "$baseline" ]]; then
    [[ $(git -C "$root" hash-object backstop.yml) == $(<"$baseline.backstop-yml") ]] || die 'backstop.yml differs from acceptance-profile baseline'
    [[ $(git -C "$root" hash-object backstop.lock) == $(<"$baseline.backstop-lock") ]] || die 'backstop.lock differs from acceptance-profile baseline'
    [[ $(snapshot_installed_cache "$root") == $(<"$baseline.installed-cache") ]] || die 'installed pack cache differs from acceptance-profile baseline'
  fi
  python3 - "$root/backstop.yml" "$root/backstop.lock" "$root/.backstop/packs" <<'PY'
import pathlib,sys,yaml
config=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
lock=yaml.safe_load(pathlib.Path(sys.argv[2]).read_text()) or {}
want={'backstop-ai/bash-toolchain'}
if set((config.get('packs') or {}).keys()) != want:
 raise SystemExit(f'acceptance profile declarations are not Bash-only: {config.get("packs")}')
if set((lock.get('packs') or {}).keys()) != want:
 raise SystemExit(f'acceptance profile lock is not Bash-only: {lock.get("packs")}')
installed=set()
for manifest in pathlib.Path(sys.argv[3]).rglob('pack.yml'):
 data=yaml.safe_load(manifest.read_text()) or {}
 if data.get('name'): installed.add(data['name'])
if installed != want:
 raise SystemExit(f'acceptance profile installed cache is not Bash-only: {sorted(installed)}')
PY
}

make_spec072_acceptance_fixture() {
  local source=$1 destination=$2 rel
  mkdir -p "$destination/specs" "$destination/plans" "$destination/scripts/tests"
  cp "$source/specs/SPEC-072-public-product-model.spec.md" "$destination/specs/SPEC-072-public-product-model.spec.md"
  cp "$source/plans/PLAN-SPEC-072-public-product-model.plan.yml" "$destination/plans/PLAN-SPEC-072-public-product-model.plan.yml"
  cp "$source/scripts/verify-public-product-model.sh" "$destination/scripts/verify-public-product-model.sh"
  cp -R "$source/scripts/tests/public-product-model" "$destination/scripts/tests/public-product-model"
  cp "$source/backstop.yml" "$destination/backstop.yml"
  cp "$source/backstop.lock" "$destination/backstop.lock"
  mkdir -p "$destination/.backstop/packs"
  cp -R "$source/.backstop/packs/." "$destination/.backstop/packs/"
  for rel in \
    specs/SPEC-072-public-product-model.spec.md \
    plans/PLAN-SPEC-072-public-product-model.plan.yml \
    scripts/verify-public-product-model.sh; do
    cmp -s "$source/$rel" "$destination/$rel" || die "acceptance fixture did not preserve pinned bytes for $rel"
  done
  diff -qr "$source/scripts/tests/public-product-model" "$destination/scripts/tests/public-product-model" >/dev/null || die 'acceptance fixture did not preserve pinned suite bytes'
  (
    cd "$destination"
    git init -q
    git config user.email fixture@backstop.sh
    git config user.name 'Backstop Fixture'
    git add backstop.yml backstop.lock specs plans scripts
    git commit -qm 'pinned SPEC-072 acceptance corpus'
  )
}

snapshot_installed_cache() {
  local root=$1
  python3 - "$root/.backstop/packs" <<'PY'
import hashlib,os,pathlib,stat,sys
root=pathlib.Path(sys.argv[1])
if not root.is_dir(): raise SystemExit('installed pack cache is absent')
h=hashlib.sha256()
for path in sorted(root.rglob('*')):
 rel=path.relative_to(root).as_posix().encode()
 mode=stat.S_IMODE(path.lstat().st_mode)
 h.update(rel+b'\0'+str(mode).encode()+b'\0')
 if path.is_symlink(): h.update(b'L'+os.readlink(path).encode())
 elif path.is_file(): h.update(b'F'+path.read_bytes())
 elif path.is_dir(): h.update(b'D')
 else: raise SystemExit(f'unsupported cache entry: {path}')
print(h.hexdigest())
PY
}

capture_post_install_baseline() {
  local root=$1 baseline=$2
  git -C "$root" diff --binary > "$baseline.patch"
  git -C "$root" diff --name-only > "$baseline.paths"
  git -C "$root" hash-object backstop.yml > "$baseline.backstop-yml"
  git -C "$root" hash-object backstop.lock > "$baseline.backstop-lock"
  snapshot_installed_cache "$root" > "$baseline.installed-cache"
}

promote_spec072_statuses() {
  local root=$1 baseline=$2
  python3 - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for rel,old,new in [
 ('specs/SPEC-072-public-product-model.spec.md','status: draft','status: implemented'),
 ('plans/PLAN-SPEC-072-public-product-model.plan.yml','status: draft','status: completed'),
]:
 p=root/rel; text=p.read_text()
 if text.count(old) != 1: raise SystemExit(f'{rel}: expected one {old!r}')
 p.write_text(text.replace(old,new,1))
PY
  local actual expected path
  local -a baseline_paths=()
  mapfile -t baseline_paths < "$baseline.paths"
  if (( ${#baseline_paths[@]} > 0 )); then
    git -C "$root" diff --binary -- "${baseline_paths[@]}" | cmp -s - "$baseline.patch" || die 'post-install baseline bytes changed during status promotion'
  else
    [[ ! -s "$baseline.patch" ]] || die 'post-install baseline patch/path receipts disagree'
  fi
  actual=$(git -C "$root" diff --name-only)
  expected=$(
    {
      cat "$baseline.paths"
      printf '%s\n' plans/PLAN-SPEC-072-public-product-model.plan.yml specs/SPEC-072-public-product-model.spec.md
    } | sort -u
  )
  [[ "$actual" == "$expected" ]] || die "unauthorized Core fixture changes beyond post-install baseline and two statuses: $actual"
  [[ $(git -C "$root" hash-object backstop.yml) == $(<"$baseline.backstop-yml") ]] || die 'backstop.yml changed after acceptance-profile baseline'
  [[ $(git -C "$root" hash-object backstop.lock) == $(<"$baseline.backstop-lock") ]] || die 'backstop.lock changed after acceptance-profile baseline'
  [[ $(snapshot_installed_cache "$root") == $(<"$baseline.installed-cache") ]] || die 'installed pack cache changed after acceptance-profile baseline'
}

assert_spec072_reference_shape() {
  local root=$1
  python3 - "$root/specs/SPEC-072-public-product-model.spec.md" <<'PY'
import pathlib,sys,yaml
raw=pathlib.Path(sys.argv[1]).read_text()
front=yaml.safe_load(raw.split('---',2)[1])
refs=[name for claim in front['claims'] for name in claim['tests']]
if len(refs) != 47 or len(set(refs)) != 44:
 raise SystemExit(f'SPEC-072 reference shape is {len(refs)}/{len(set(refs))}, want 47/44')
PY
}

make_invocation_probe() {
  local probe=$1
  cat > "$probe" <<'SH'
bash() {
  if [[ ${1:-} == scripts/verify-public-product-model.sh ]]; then
    printf '1\n' >> "${BACKSTOP_BASH_COUNT_FILE:?}"
  fi
  command bash "$@"
}
SH
}

run_gate_report() {
  local root=$1 report=$2 stderr_file=$3 probe=$4 count_file=$5
  set +e
  (cd "$root"; BASH_ENV="$probe" BACKSTOP_BASH_COUNT_FILE="$count_file" BACKSTOP_PACK_SANDBOX=external \
    "$backstop_bin" --json gate --all >"$report" 2>"$stderr_file")
  local status=$?
  set -e
  if (( status != 0 )); then
    cat "$stderr_file" >&2
    cat "$report" >&2
    return "$status"
  fi
}

run_spec072_gate_report() {
  local root=$1 report=$2 stderr_file=$3 probe=$4 count_file=$5 pinned_source=$6
  set +e
  (cd "$root"; BASH_ENV="$probe" BACKSTOP_BASH_COUNT_FILE="$count_file" \
    BACKSTOP_PUBLIC_MODEL_ROOT="$pinned_source" BACKSTOP_PUBLIC_MODEL_GIT_ROOT="$pinned_source" \
    BACKSTOP_PACK_SANDBOX=external \
    "$backstop_bin" --json gate \
      --file specs/SPEC-072-public-product-model.spec.md \
      --file plans/PLAN-SPEC-072-public-product-model.plan.yml \
      --file scripts/verify-public-product-model.sh >"$report" 2>"$stderr_file")
  local status=$?
  set -e
  if (( status != 0 )); then
    cat "$stderr_file" >&2
    cat "$report" >&2
    return "$status"
  fi
}

assert_gate_steps() {
  local report=$1
  shift
  python3 - "$report" "$@" <<'PY'
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
steps={step['step_name']:step for step in data['steps']}
for name in sys.argv[2:]:
 step=steps.get(name)
 if not step or step['status'] != 'pass' or step.get('violations'):
  raise SystemExit(f'{name} was not a zero-violation pass: {step}')
PY
}

run_spec072_lane() (
  local candidate_source=$1 lane=$2 source_kind=${3:-local}
  local fixture source consumer probe count_file report stderr_file baseline
  fixture=$(mktemp -d /tmp/backstop-spec072.XXXXXX)
  trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
  source="$fixture/pinned-core"; consumer="$fixture/consumer"
  make_core_fixture "$source"
  make_spec072_acceptance_fixture "$source" "$consumer"
  establish_spec072_pack_profile "$consumer" "$candidate_source" "$source_kind"
  [[ $(git -C "$source" rev-parse HEAD) == "$core_commit" && $(git -C "$source" rev-parse 'HEAD^{tree}') == "$core_tree" ]] || die 'pinned Core identity changed during acceptance-profile setup'
  [[ -z $(git -C "$source" status --porcelain) ]] || die 'pinned Core bytes changed during acceptance-profile setup'
  git -C "$consumer" diff --quiet HEAD -- . \
    ':(exclude)backstop.yml' ':(exclude)backstop.lock' || die 'acceptance profile changed tracked non-config bytes before status promotion'
  baseline="$fixture/post-install-baseline"
  capture_post_install_baseline "$consumer" "$baseline"
  assert_spec072_reference_shape "$consumer"
  promote_spec072_statuses "$consumer" "$baseline"
  probe="$fixture/bash-env-probe.sh"; count_file="$fixture/verifier-count"
  report="$fixture/gate.json"; stderr_file="$fixture/gate.stderr"
  make_invocation_probe "$probe"
  run_spec072_gate_report "$consumer" "$report" "$stderr_file" "$probe" "$count_file" "$source"
  assert_gate_steps "$report" pack_lock_verification artifact_validation pack_engines test_verification artifact_status_drift
  [[ $(wc -l < "$count_file" | tr -d ' ') == 1 ]] || die 'canonical verifier was not invoked exactly once by the assembled gate'
  (cd "$source"; env -u BASH_ENV -u BACKSTOP_BASH_COUNT_FILE bash scripts/verify-public-product-model.sh >/dev/null; while IFS= read -r suite; do env -u BASH_ENV -u BACKSTOP_BASH_COUNT_FILE bash "$suite" >/dev/null; done < <(find scripts/tests/public-product-model -type f -name '*.sh' | sort))
  [[ $(git -C "$source" rev-parse HEAD) == "$core_commit" && $(git -C "$source" rev-parse 'HEAD^{tree}') == "$core_tree" && -z $(git -C "$source" status --porcelain) ]] || die 'pinned Core source changed during acceptance execution'
  assert_spec072_pack_profile "$consumer" "$baseline"
  printf 'lane=%s\npinned_core_identity=pass\nbash_only_acceptance_profile=pass\nconfiguration_baseline=pass\nstatus_only_diff=pass\nscoped_assembled_gate=pass\nspec072_references=47\nspec072_distinct_functions=44\nspec072_absent=0\ncanonical_verifier_invocations=1\nindependent_suites=pass\ntest_verification_absent=0\nartifact_status_broken_promises=0\ncandidate_commit=%s\ncandidate_tree=%s\ncandidate_digest=%s\n' "$lane" "$candidate_commit" "$candidate_tree" "$candidate_digest"
)

author_mixed_artifacts() {
  local root=$1 include_bash=$2
  python3 - "$root" "$include_bash" <<'PY'
from pathlib import Path
import datetime,sys,yaml
root=Path(sys.argv[1]); funcs=['TestGoToolchainBaseline']+(['TestBashToolchainMixedFixture'] if sys.argv[2]=='true' else []); date=datetime.date.today().isoformat()
bundle={'title':'Mixed Toolchain Consumer','number':'BUNDLE-001','created':date,'schema_version':'bundle/v2','bundle':{'name':'mixed-toolchain-consumer','version':'0.1.0','created':date,'category':'tool'},'status':{'maturity':'exploring'},'problem':{'summary':'Verify mixed Go and Bash discovery through assembled gates.','user_story':'As a pack author, I need both toolchains to coexist.'},'requirements':[{'id':f'REQ-{i:03d}','version':'1.0.0','text':f'Discover and execute {n}.','versions':[{'version':'1.0.0','text':f'Discover and execute {n}.'}]} for i,n in enumerate(funcs,1)],'spec_seeds':[{'id':'SPEC-001','owns':[f'REQ-{i:03d}' for i in range(1,len(funcs)+1)]}]}
spec={'title':'SPEC-001: Mixed Toolchain Consumer','number':'SPEC-001','created':date,'status':'implemented','schema_version':'spec/v1','spec_version':'1.0.0','implementation':{'summary':'Exercise declared Go and Bash toolchains.','subject':'mixed-toolchain-consumer'},'verification':{'level':'build','test_command':'backstop gate --all'},'requirements':[{'id':f'REQ-{i:03d}','supports':[f'mixed-toolchain-consumer:REQ-{i:03d}@1.0.0'],'text':f'Discover and execute {n}.'} for i,n in enumerate(funcs,1)],'claims':[{'id':f'CLM-{i:03d}','requirement':f'REQ-{i:03d}','text':f'{n} is discovered and green.','tests':[n]} for i,n in enumerate(funcs,1)],'contracts':[{'file':'example_test.go','provides':[{'name':'TestGoToolchainBaseline','kind':'function','signature':'func TestGoToolchainBaseline(t *testing.T)'}]}]}
claims=[f'CLM-{i:03d}' for i in range(1,len(funcs)+1)]
plan={'plan_id':'PLAN-SPEC-001','spec_id':'SPEC-001','spec_version':'1.0.0','created':date,'status':'completed','target_repo':'mixed-consumer','test_command':'backstop gate --all','phases':[{'id':'phase-1','name':'Mixed acceptance','tasks':[{'id':'TASK-001','type':'test','title':'Declare mixed tests','description':'Declare both toolchain tests.','files':['example_test.go','scripts/tests/example.sh'],'claims':claims,'test_names':funcs,'depends_on':[]},{'id':'TASK-002','type':'implementation','title':'Install mixed fixtures','description':'Install a buildable Go package, the test fixtures, and the verifier.','files':['example.go','example_test.go','scripts/tests/example.sh','scripts/verify-public-product-model.sh'],'claims':claims,'depends_on':['TASK-001']},{'id':'TASK-003','type':'verification','title':'Run assembled gate','description':'Run Backstop.','files':['example.go','example_test.go','scripts/tests/example.sh'],'claims':claims,'depends_on':['TASK-002']}]}]}
def md(path,data,sections): path.write_text('---\n'+yaml.safe_dump(data,sort_keys=False)+'---\n\n# '+data['title']+'\n\n'+''.join(f'## {s}\n\nAcceptance fixture.\n\n' for s in sections))
md(root/'bundles/BUNDLE-001-mixed-toolchain-consumer.bundle.md',bundle,['Current Thinking','Spec Seeds']); md(root/'specs/SPEC-001-mixed-toolchain-consumer.spec.md',spec,['Overview','Requirements','Implementation','Verification']); (root/'plans/PLAN-SPEC-001-mixed-toolchain-consumer.plan.yml').write_text('---\n'+yaml.safe_dump(plan,sort_keys=False)+'---\n')
PY
}

run_mixed_lane() (
  local candidate_source=$1 source_kind=${2:-local} fixture probe count_file before after stderr_file go_digest_before go_digest_after
  fixture=$(mktemp -d /tmp/backstop-mixed.XXXXXX)
  trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
  cp -R "$repo_root/testdata/consumer/mixed/." "$fixture/"
  mkdir -p "$fixture"/{bundles,specs,plans,scripts/tests}
  cp "$repo_root/scripts/verify-public-product-model.sh" "$fixture/scripts/verify-public-product-model.sh"
  chmod +x "$fixture/scripts/verify-public-product-model.sh" "$fixture/scripts/tests/example.sh"
  (cd "$fixture"; git init -q; git config user.email fixture@backstop.sh; git config user.name Fixture; printf '# mixed\n' > README.md; git add README.md; git commit -qm init; "$backstop_bin" artifact new bundle --slug mixed-toolchain-consumer >/dev/null; "$backstop_bin" artifact new spec --slug mixed-toolchain-consumer >/dev/null; "$backstop_bin" artifact new plan --source SPEC-001 --slug mixed-toolchain-consumer >/dev/null)
  author_mixed_artifacts "$fixture" false
  printf 'project: mixed-toolchain-consumer\npacks: {}\n' > "$fixture/backstop.yml"
  (cd "$fixture"; "$backstop_bin" pack add "$core_repo/.backstop/packs/backstop-ai/go-toolchain" --version 1.9.0 >/dev/null; "$backstop_bin" artifact validate --all >/dev/null)
  go_digest_before=$(sed -n '/backstop-ai\/go-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' "$fixture/backstop.lock")
  [[ -n "$go_digest_before" ]] || die 'Go baseline digest is absent'
  probe="$fixture/bash-env-probe.sh"; count_file="$fixture/bash-count"; make_invocation_probe "$probe"
  before="$fixture/go-only.json"; stderr_file="$fixture/go-only.stderr"
  run_gate_report "$fixture" "$before" "$stderr_file" "$probe" "$count_file"
  assert_gate_steps "$before" pack_lock_verification pack_engines test_verification
  author_mixed_artifacts "$fixture" true
  install_candidate "$fixture" "$candidate_source" "$source_kind"
  go_digest_after=$(sed -n '/backstop-ai\/go-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' "$fixture/backstop.lock")
  [[ "$go_digest_after" == "$go_digest_before" ]] || die 'Bash addition changed the locked Go toolchain identity'
  (cd "$fixture"; "$backstop_bin" artifact validate --all >/dev/null)
  : > "$count_file"
  after="$fixture/mixed.json"; stderr_file="$fixture/mixed.stderr"
  run_gate_report "$fixture" "$after" "$stderr_file" "$probe" "$count_file"
  assert_gate_steps "$after" pack_lock_verification pack_engines test_verification
  python3 - "$before" "$after" <<'PY'
import json,sys
def evidence(path):
 data=json.load(open(path, encoding='utf-8')); steps={s['step_name']:s for s in data['steps']}
 return tuple((steps[n]['status'],len(steps[n].get('violations',[]))) for n in ('pack_engines','test_verification'))
if evidence(sys.argv[1]) != (('pass',0),('pass',0)) or evidence(sys.argv[2]) != (('pass',0),('pass',0)):
 raise SystemExit('Go baseline or mixed gate lost discovery/verdict evidence')
PY
  [[ $(wc -l < "$count_file" | tr -d ' ') == 1 ]] || die 'mixed Bash verifier invocation count is not one'
  printf 'go_discovery_unchanged=pass\ngo_verdict_unchanged=pass\nbash_discovery=pass\nbash_verifier_invocations=1\n'
)

make_incomplete_consumer() {
  local root=$1
  mkdir -p "$root"/{bundles,specs,plans,scripts/tests/consumer,testdata/classification,testdata/name-patterns}
  cp "$repo_root/scripts/tests/bash-toolchain/manifest-contract.sh" "$root/scripts/tests/consumer/selected.sh"
  cp "$repo_root/testdata/classification/path-matrix.txt" "$root/testdata/classification/path-matrix.txt"
  cp "$repo_root/testdata/name-patterns/positive.txt" "$root/testdata/name-patterns/positive.txt"
  cp "$repo_root/testdata/name-patterns/negative.txt" "$root/testdata/name-patterns/negative.txt"
  cat > "$root/scripts/verify-public-product-model.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
TestBashToolchainCanonicalVerifierPath() { :; }
TestBashToolchainCanonicalVerifierPath
bash scripts/tests/consumer/selected.sh
SH
  chmod +x "$root/scripts/verify-public-product-model.sh" "$root/scripts/tests/consumer/selected.sh"
  (cd "$root"; git init -q; git config user.email fixture@backstop.sh; git config user.name Fixture; printf '# incomplete consumer\n' > README.md; git add README.md; git commit -qm init; "$backstop_bin" artifact new bundle --slug incomplete-bash-consumer >/dev/null; "$backstop_bin" artifact new spec --slug incomplete-bash-consumer >/dev/null; "$backstop_bin" artifact new plan --source SPEC-001 --slug incomplete-bash-consumer >/dev/null)
  python3 - "$root" <<'PY'
from pathlib import Path
import datetime,sys,yaml
root=Path(sys.argv[1]); date=datetime.date.today().isoformat()
funcs=['TestBashToolchainManifestUsesExistingCoreSurfaces','TestBashToolchainClassificationIsNarrowAndComplete','TestBashToolchainNamePatternsDeclarationMatrix','TestBashToolchainCanonicalVerifierPath']
bundle={'title':'Incomplete Bash Consumer','number':'BUNDLE-001','created':date,'schema_version':'bundle/v2','bundle':{'name':'incomplete-bash-consumer','version':'0.1.0','created':date,'category':'tool'},'status':{'maturity':'exploring'},'problem':{'summary':'Prove incomplete Bash discovery remains loud.','user_story':'As a pack author, I need incomplete mechanisms to block.'},'requirements':[{'id':f'REQ-{i:03d}','version':'1.0.0','text':f'Discover {n}.','versions':[{'version':'1.0.0','text':f'Discover {n}.'}]} for i,n in enumerate(funcs,1)],'spec_seeds':[{'id':'SPEC-001','owns':[f'REQ-{i:03d}' for i in range(1,len(funcs)+1)]}]}
spec={'title':'SPEC-001: Incomplete Bash Consumer','number':'SPEC-001','created':date,'status':'implemented','schema_version':'spec/v1','spec_version':'1.0.0','implementation':{'summary':'Exercise an intentionally incomplete Bash pack.','subject':'scripts/verify-public-product-model.sh'},'verification':{'level':'build','test_command':'backstop gate --all'},'requirements':[{'id':f'REQ-{i:03d}','supports':[f'incomplete-bash-consumer:REQ-{i:03d}@1.0.0'],'text':f'Discover {n}.'} for i,n in enumerate(funcs,1)],'claims':[{'id':f'CLM-{i:03d}','requirement':f'REQ-{i:03d}','text':f'{n} is discovered.','tests':[n]} for i,n in enumerate(funcs,1)],'contracts':[{'file':'scripts/verify-public-product-model.sh','provides':[{'name':'TestBashToolchainCanonicalVerifierPath','kind':'function','signature':'TestBashToolchainCanonicalVerifierPath()'}]}]}
claims=[f'CLM-{i:03d}' for i in range(1,len(funcs)+1)]
plan={'plan_id':'PLAN-SPEC-001','spec_id':'SPEC-001','spec_version':'1.0.0','created':date,'status':'completed','target_repo':'incomplete-consumer','test_command':'backstop gate --all','phases':[{'id':'phase-1','name':'Incomplete acceptance','tasks':[{'id':'TASK-001','type':'test','title':'Declare tests','description':'Declare exact fixture tests.','files':['scripts/tests/consumer/selected.sh','scripts/verify-public-product-model.sh'],'claims':claims,'test_names':funcs,'depends_on':[]},{'id':'TASK-002','type':'implementation','title':'Install fixture','description':'Install the consumer fixture.','files':['scripts/tests/consumer/selected.sh','scripts/verify-public-product-model.sh'],'claims':claims,'depends_on':['TASK-001']},{'id':'TASK-003','type':'verification','title':'Run gate','description':'Run assembled Backstop gate.','files':['scripts/tests/consumer/selected.sh'],'claims':claims,'depends_on':['TASK-002']}]}]}
def md(path,data,sections): path.write_text('---\n'+yaml.safe_dump(data,sort_keys=False)+'---\n\n# '+data['title']+'\n\n'+''.join(f'## {s}\n\nAcceptance fixture.\n\n' for s in sections))
md(root/'bundles/BUNDLE-001-incomplete-bash-consumer.bundle.md',bundle,['Current Thinking','Spec Seeds']); md(root/'specs/SPEC-001-incomplete-bash-consumer.spec.md',spec,['Overview','Requirements','Implementation','Verification']); (root/'plans/PLAN-SPEC-001-incomplete-bash-consumer.plan.yml').write_text('---\n'+yaml.safe_dump(plan,sort_keys=False)+'---\n')
PY
  printf 'project: incomplete-bash-consumer\npacks: {}\n' > "$root/backstop.yml"
  (cd "$root"; "$backstop_bin" artifact validate --all)
}

run_incomplete_lane() (
  local mutation=$1 staged_pack=$2 fixture status report expected_names expected_class
  fixture=$(mktemp -d /tmp/backstop-incomplete.XXXXXX)
  trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
  make_incomplete_consumer "$fixture/consumer"
  cp -R "$staged_pack" "$fixture/pack"
  python3 - "$fixture/pack/pack.yml" "$mutation" <<'PY'
import pathlib,sys,yaml
path=pathlib.Path(sys.argv[1]); mutation=sys.argv[2]; data=yaml.safe_load(path.read_text())
if mutation=='missing-classification-test': data['classification'].pop('test',None)
elif mutation=='missing-suite-path': data['classification']['test']=[x for x in data['classification']['test'] if x!='scripts/tests/**/*.sh']
elif mutation=='missing-verifier-path': data['classification']['test']=[x for x in data['classification']['test'] if x!='scripts/verify-public-product-model.sh']
elif mutation=='missing-test-name-patterns': data.pop('test_name_patterns',None)
elif mutation=='missing-test-engine': data['engines'].pop('bash-test',None); data['content']['ruleset']['rules']=[]
elif mutation!='absent-pack': raise SystemExit('unknown mutation')
path.write_text(yaml.safe_dump(data,sort_keys=False))
PY
  cp "$fixture/pack/pack.yml" "$fixture/consumer/pack.yml"
  if [[ "$mutation" == absent-pack ]]; then
    printf 'project: incomplete-bash-consumer\npacks:\n  backstop-ai/bash-toolchain: 0.1.0\n' > "$fixture/consumer/backstop.yml"
  fi
  if [[ "$mutation" != absent-pack ]]; then
    set +e
    (cd "$fixture/consumer"; "$backstop_bin" pack add "$fixture/pack" --version 0.1.0) >"$fixture/add.out" 2>&1
    status=$?
    set -e
    if (( status != 0 )); then
      [[ "$mutation" == missing-test-engine ]] || die "$mutation failed during pack add instead of its expected assembled surface"
      grep -Eiq 'pack check|validation|structural' "$fixture/add.out" || die "missing-test-engine add failure lacked a manifest-construction diagnostic: $(tr '\n' ' ' < "$fixture/add.out")"
      printf 'mutation=%s\noperation_expected=fail\noperation_observed=fail\nreal_operation=backstop-pack-add\nblocking_stage=pack_add\nexpected_class=manifest_engine_construction\nobserved_class=manifest_engine_construction\n' "$mutation"
      return 0
    fi
  fi
  report="$fixture/gate.json"
  set +e
  (cd "$fixture/consumer"; BACKSTOP_PACK_SANDBOX=external "$backstop_bin" --json gate --all >"$report" 2>"$fixture/gate.stderr")
  status=$?
  set -e
  (( status != 0 )) || die "$mutation unexpectedly passed its assembled gate"
  case "$mutation" in
    absent-pack) expected_names=''; expected_class='declared_pack_lock_or_install' ;;
    missing-classification-test) expected_names='TestBashToolchainManifestUsesExistingCoreSurfaces,TestBashToolchainClassificationIsNarrowAndComplete,TestBashToolchainNamePatternsDeclarationMatrix,TestBashToolchainCanonicalVerifierPath'; expected_class='absent_mandated_tests' ;;
    missing-suite-path) expected_names='TestBashToolchainManifestUsesExistingCoreSurfaces,TestBashToolchainClassificationIsNarrowAndComplete,TestBashToolchainNamePatternsDeclarationMatrix'; expected_class='absent_mandated_tests' ;;
    missing-verifier-path) expected_names='TestBashToolchainCanonicalVerifierPath'; expected_class='absent_mandated_tests' ;;
    missing-test-name-patterns) expected_names='TestBashToolchainManifestUsesExistingCoreSurfaces,TestBashToolchainClassificationIsNarrowAndComplete,TestBashToolchainNamePatternsDeclarationMatrix,TestBashToolchainCanonicalVerifierPath'; expected_class='absent_mandated_tests' ;;
    *) die "unexpected gate-stage mutation $mutation" ;;
  esac
  python3 - "$report" "$mutation" "$expected_class" "$expected_names" <<'PY'
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
if data.get('pass'): raise SystemExit(f'{sys.argv[2]} produced a green gate')
violations=[v for step in data.get('steps',[]) for v in step.get('violations',[])]
if not violations:
 raise SystemExit(f'{sys.argv[2]} produced no blocking gate evidence')
evidence='\n'.join(str(v.get('rule',''))+' '+str(v.get('message','')) for v in violations)
if sys.argv[3]=='declared_pack_lock_or_install':
 if not any(token in evidence.lower() for token in ('lock','install','declared','pack')):
  raise SystemExit('absent-pack did not expose a pack declaration/lock/install diagnostic')
else:
 absent=[name for name in sys.argv[4].split(',') if name and name not in evidence]
 if absent: raise SystemExit(f'{sys.argv[2]} did not identify affected absent names: {absent}; evidence={evidence}')
PY
  printf 'mutation=%s\ngate_expected=fail\ngate_observed=fail\nreal_operation=backstop-gate-all\nexpected_class=%s\nobserved_class=%s\naffected_names=%s\n' "$mutation" "$expected_class" "$expected_class" "${expected_names:-none}"
)

compute_candidate_digest() (
  local staged_pack=$1 fixture digest
  fixture=$(mktemp -d /tmp/backstop-candidate-digest.XXXXXX)
  trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
  printf 'project: candidate-digest\npacks: {}\n' > "$fixture/backstop.yml"
  (cd "$fixture"; "$backstop_bin" pack add "$staged_pack" --version 0.1.0 >/dev/null)
  digest=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' "$fixture/backstop.lock")
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die 'Backstop did not generate a candidate content digest'
  printf 'BACKSTOP_CANDIDATE_DIGEST=%s\n' "$digest"
)

derive_candidate_identity() {
  local digest_receipt
  [[ -z $(git -C "$repo_root" status --porcelain) ]] || {
    printf 'candidate_identity_recompute=blocked\ncandidate_identity_reason=working_tree_not_committed\n'
    exit 76
  }
  candidate_commit=$(git -C "$repo_root" rev-parse HEAD)
  candidate_tree=$(git -C "$repo_root" rev-parse 'HEAD^{tree}')
  digest_receipt=$(BACKSTOP_BIN="$backstop_bin" bash "$repo_root/scripts/stage-local-candidate.sh" \
    "$candidate_commit" "$candidate_tree" -- bash "$0" _candidate-digest)
  candidate_digest=$(sed -n 's/^BACKSTOP_CANDIDATE_DIGEST=//p' <<<"$digest_receipt")
  [[ "$candidate_digest" =~ ^[0-9a-f]{64}$ ]] || die 'candidate digest receipt was malformed'
  export BACKSTOP_CANDIDATE_COMMIT="$candidate_commit"
  export BACKSTOP_CANDIDATE_TREE="$candidate_tree"
  export BACKSTOP_CANDIDATE_DIGEST="$candidate_digest"
}

emit_candidate_identity() {
  derive_candidate_identity
  printf 'BACKSTOP_CANDIDATE_COMMIT=%s\nBACKSTOP_CANDIDATE_TREE=%s\nBACKSTOP_CANDIDATE_DIGEST=%s\n' \
    "$candidate_commit" "$candidate_tree" "$candidate_digest"
}

run_remote_release_lane() (
  local version=${BACKSTOP_RELEASE_VERSION:-v0.1.0}
  local remote=${BACKSTOP_PACK_REMOTE:-https://github.com/backstop-ai/bash-toolchain.git}
  local coordinate="backstop-ai/bash-toolchain@${version#v}"
  local fixture remote_commit remote_tree installed_remote locked_digest
  require_candidate_identity
  fixture=$(mktemp -d /tmp/backstop-remote-release.XXXXXX)
  trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
  if ! git ls-remote --exit-code --tags "$remote" "refs/tags/$version" >/dev/null 2>&1; then
    printf 'publication_boundary=blocked\nrequired_remote=backstop-ai/bash-toolchain@%s\n' "$version" >&2
    exit 69
  fi
  require_core_binary
  git init -q "$fixture/identity"
  git -C "$fixture/identity" fetch -q --depth 1 "$remote" "refs/tags/$version"
  remote_commit=$(git -C "$fixture/identity" rev-parse 'FETCH_HEAD^{commit}')
  remote_tree=$(git -C "$fixture/identity" rev-parse 'FETCH_HEAD^{tree}')
  [[ "$remote_commit" == "$candidate_commit" && "$remote_tree" == "$candidate_tree" ]] || die "remote identity $remote_commit/$remote_tree differs from accepted candidate"

  mkdir "$fixture/add-consumer" "$fixture/install-consumer"
  printf 'project: remote-add-consumer\npacks: {}\n' > "$fixture/add-consumer/backstop.yml"
  install_candidate "$fixture/add-consumer" "$coordinate" remote
  cp "$fixture/add-consumer/backstop.yml" "$fixture/install-consumer/backstop.yml"
  cp "$fixture/add-consumer/backstop.lock" "$fixture/install-consumer/backstop.lock"
  (cd "$fixture/install-consumer"; "$backstop_bin" pack install >/dev/null)
  installed_remote="$fixture/install-consumer/.backstop/packs/backstop-ai/bash-toolchain"
  [[ -f "$installed_remote/pack.yml" ]] || die 'fresh remote install did not materialize pack.yml'
  grep -Fqx 'name: backstop-ai/bash-toolchain' "$installed_remote/pack.yml" || die 'fresh remote install has wrong pack name'
  grep -Fqx 'version: "0.1.0"' "$installed_remote/pack.yml" || die 'fresh remote install has wrong pack version'
  locked_digest=$(sed -n '/backstop-ai\/bash-toolchain:/,/version:/s/^[[:space:]]*content_hash:[[:space:]]*//p' "$fixture/install-consumer/backstop.lock")
  [[ "$locked_digest" == "$candidate_digest" ]] || die 'fresh remote install digest differs from accepted digest'

  run_spec072_lane "$coordinate" remote-cardinality remote
  run_spec072_lane "$coordinate" remote-terminal remote
  run_mixed_lane "$coordinate" remote
  while read -r mutation; do [[ -z "$mutation" ]] || run_incomplete_lane "$mutation" "$installed_remote"; done < <(sed -n 's/^[[:space:]]*- //p' "$repo_root/testdata/consumer/mutations/matrix.yml")
  printf 'remote_install=pass\ncandidate_remote_identity=equal\npost_tag_acceptance=pass\ncandidate_commit=%s\ncandidate_tree=%s\ncandidate_digest=%s\n' "$candidate_commit" "$candidate_tree" "$candidate_digest"
)

case "${1:-complete}" in
  complete)
    if [[ -z "$candidate_commit" || -z "$candidate_tree" || -z "$candidate_digest" ]]; then
      derive_candidate_identity
    fi
    require_candidate_identity
    "$0" local-candidate
    "$0" remote-release
    ;;
  candidate-identity) emit_candidate_identity ;;
  spec072-cardinality) require_core_binary; stage_callback _spec072-cardinality ;;
  spec072-terminal) require_core_binary; stage_callback _spec072-terminal ;;
  mixed-toolchain) require_core_binary; stage_callback _mixed-toolchain ;;
  incomplete-pack) require_core_binary; mutation=${2:?mutation required}; stage_callback _incomplete-pack "$mutation" ;;
  local-candidate)
    require_candidate_identity
    require_core_binary
    "$0" spec072-cardinality; "$0" spec072-terminal; "$0" mixed-toolchain
    while read -r mutation; do [[ -z "$mutation" ]] || "$0" incomplete-pack "$mutation"; done < <(sed -n 's/^[[:space:]]*- //p' "$repo_root/testdata/consumer/mutations/matrix.yml")
    printf 'prepublication_acceptance=pass\ncandidate_commit=%s\ncandidate_tree=%s\ncandidate_digest=%s\n' "$candidate_commit" "$candidate_tree" "$candidate_digest"
    ;;
  remote-release) run_remote_release_lane ;;
  _spec072-cardinality) run_spec072_lane "$2" cardinality ;;
  _spec072-terminal) run_spec072_lane "$2" terminal ;;
  _mixed-toolchain) run_mixed_lane "$2" ;;
  _incomplete-pack) run_incomplete_lane "$2" "$3" ;;
  _candidate-digest) compute_candidate_digest "$2" ;;
  *) printf 'usage: %s {complete|candidate-identity|local-candidate|remote-release|spec072-cardinality|spec072-terminal|mixed-toolchain|incomplete-pack}\n' "$0" >&2; exit 64 ;;
esac
