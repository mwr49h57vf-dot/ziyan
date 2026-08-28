#!/usr/bin/env bash
# Build an App/GameEntry-only candidate on top of the frozen D1 candidate.
#
# The primary checkout is intentionally dirty.  Every compile happens in two
# fresh detached worktrees at the explicitly supplied GameEntry revision.
# ziyan_framecap is never rebuilt, replaced, or copied into this candidate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat >&2 <<'EOF'
usage: zy_p3_build_gameentry_app_candidate.sh \
  --source-revision <40-hex-git-revision> \
  --gameentry-base-revision <40-hex-git-revision> \
  --d1-manifest <d1_release_manifest.env> \
  --release-id <release-id> \
  --out <new-empty-evidence-directory>
EOF
  exit 2
}

SOURCE_REVISION=""
GAMEENTRY_BASE_REVISION=""
D1_MANIFEST=""
RELEASE_ID=""
OUT_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-revision) [ "$#" -ge 2 ] || usage; SOURCE_REVISION="$2"; shift 2 ;;
    --gameentry-base-revision) [ "$#" -ge 2 ] || usage; GAMEENTRY_BASE_REVISION="$2"; shift 2 ;;
    --d1-manifest) [ "$#" -ge 2 ] || usage; D1_MANIFEST="$2"; shift 2 ;;
    --release-id) [ "$#" -ge 2 ] || usage; RELEASE_ID="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; OUT_DIR="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || {
  echo "APP_BUILD=FAIL reason=source_revision_must_be_exact_40_hex" >&2
  exit 2
}
[[ "$GAMEENTRY_BASE_REVISION" =~ ^[0-9a-f]{40}$ ]] || {
  echo "APP_BUILD=FAIL reason=gameentry_base_revision_must_be_exact_40_hex" >&2
  exit 2
}
[ -n "$D1_MANIFEST" ] && [ -f "$D1_MANIFEST" ] || {
  echo "APP_BUILD=FAIL reason=d1_manifest_missing" >&2
  exit 2
}
[ -n "$RELEASE_ID" ] || {
  echo "APP_BUILD=FAIL reason=release_id_required" >&2
  exit 2
}
[ -n "$OUT_DIR" ] || {
  echo "APP_BUILD=FAIL reason=empty_output_path" >&2
  exit 2
}
OUT_DIR="$(cd "$(dirname "$OUT_DIR")" && pwd)/$(basename "$OUT_DIR")"
if [ -e "$OUT_DIR" ]; then
  [ -d "$OUT_DIR" ] && [ -z "$(find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
    echo "APP_BUILD=FAIL reason=output_directory_must_be_new_and_empty path=$OUT_DIR" >&2
    exit 2
  }
else
  mkdir -p "$OUT_DIR"
fi

# shellcheck disable=SC1090
. "$D1_MANIFEST"
EXPECTED_D1_RELEASE="P3_D1_DUALFRAME_LEASE_20260827"
[ "${D1_RELEASE_ID:-}" = "$EXPECTED_D1_RELEASE" ] || {
  echo "APP_BUILD=FAIL reason=unexpected_d1_release_id value=${D1_RELEASE_ID:-unset}" >&2
  exit 2
}
[ "${D1_SOURCE_REVISION:-}" = "fbe70fb18db2ed6178024c37380159339d009784" ] || {
  echo "APP_BUILD=FAIL reason=unexpected_d1_source_revision value=${D1_SOURCE_REVISION:-unset}" >&2
  exit 2
}

python3 "$ROOT/tools/zy_p3_candidate_package.py" verify \
  --manifest "${D1_ROOTFUL_DEB}.manifest.json"
python3 "$ROOT/tools/zy_p3_candidate_package.py" verify \
  --manifest "${D1_ROOTLESS_DEB}.manifest.json"

python3 - "$D1_ROOTFUL_DEB.manifest.json" "$D1_ROOTLESS_DEB.manifest.json" <<'PY'
import json
import sys
from pathlib import Path

for value in sys.argv[1:]:
    data = json.loads(Path(value).read_text(encoding="utf-8"))
    changed = data.get("changed_payloads")
    if not isinstance(changed, list) or len(changed) != 1:
        raise SystemExit(f"d1_candidate_payload_lineage_invalid:{value}")
    if not all(str(item).endswith("/usr/lib/ziyan/bin/ziyan_framecap")
               or str(item) == "usr/lib/ziyan/bin/ziyan_framecap"
               for item in changed):
        raise SystemExit(f"d1_candidate_is_not_framecap_only:{value}")
    if data.get("release_id") != "P3_D1_DUALFRAME_LEASE_20260827":
        raise SystemExit(f"d1_candidate_release_mismatch:{value}")
PY

command -v git >/dev/null
command -v make >/dev/null
[ -d "${THEOS:-}" ] || {
  echo "APP_BUILD=FAIL reason=THEOS_missing" >&2
  exit 2
}

SOURCE_REVISION_ACTUAL="$(git rev-parse --verify "$SOURCE_REVISION^{commit}")"
[ "$SOURCE_REVISION_ACTUAL" = "$SOURCE_REVISION" ] || {
  echo "APP_BUILD=FAIL reason=source_revision_resolution_mismatch" >&2
  exit 2
}
GAMEENTRY_BASE_ACTUAL="$(git rev-parse --verify "$GAMEENTRY_BASE_REVISION^{commit}")"
[ "$GAMEENTRY_BASE_ACTUAL" = "$GAMEENTRY_BASE_REVISION" ] || {
  echo "APP_BUILD=FAIL reason=gameentry_base_revision_resolution_mismatch" >&2
  exit 2
}
git merge-base --is-ancestor "$GAMEENTRY_BASE_REVISION" "$SOURCE_REVISION" || {
  echo "APP_BUILD=FAIL reason=source_is_not_gameentry_base_descendant" >&2
  exit 2
}
if [ "$SOURCE_REVISION" != "$GAMEENTRY_BASE_REVISION" ]; then
  # 2508084's app target references a sidecar class while omitting its
  # implementation from Makefile.  The accepted child removes that iOS-side
  # dependency and may carry the narrowly-scoped detached-runner lifecycle
  # fix; no GameEntry/framecap/package path may drift.
  expected_sidecar_delta=$'objc/app/ZiYanDumpManager.m\nobjc/app/ZiYanLLMSidecarClient.h\nobjc/app/ZiYanLLMSidecarClient.m\nobjc/app/ZiYanLiveVisionLearn.m\nobjc/app/ZiYanScriptGenerator.m'
  actual_sidecar_delta="$(git diff --name-only "$GAMEENTRY_BASE_REVISION" "$SOURCE_REVISION")"
  expected_diagnostic_delta=$'objc/app/AgentSessionController.m\n'"$expected_sidecar_delta"
  # One named, reviewable candidate is permitted to add runner-owned lease
  # renewal and bounded frame waiting.  Its exact revision and delta prevent
  # this candidate harness from becoming an arbitrary source-overlay path.
  expected_lease_runner_delta=$'lua/modules/GameEntry.lua\nobjc/app/AgentSessionController.m\n'"$expected_sidecar_delta"$'\ntools/test_game_entry_contract.py\ntools/test_game_entry_lease_runner_contract.py'
  lease_runner_revision='edd295e263b059482a189300ec642bc7b9783d84'
  expected_home_command_delta=$'lua/modules/GameEntry.lua\nobjc/app/AgentSessionController.m\nobjc/app/ZiYanDumpManager.m\nobjc/app/ZiYanHomeViewController.m\nobjc/app/ZiYanLLMSidecarClient.h\nobjc/app/ZiYanLLMSidecarClient.m\nobjc/app/ZiYanLiveVisionLearn.m\nobjc/app/ZiYanScriptGenerator.m\ntools/test_game_entry_contract.py\ntools/test_game_entry_lease_runner_contract.py'
  home_command_revision='c3855cd346ab0e4f7dc53a19010c3b3706e6cca3'
  # This named snapshot contains the already-reviewed AI self-research app
  # path plus the embedded Home consumer fix.  Framecap is intentionally
  # absent from the snapshot and remains supplied by the immutable D1 base.
  expected_full_app_snapshot_delta=$'Agent/Core/agent_runtime.lua\nlua/modules/GameEntry.lua\nobjc/app/AgentGameViewController.h\nobjc/app/AgentGameViewController.m\nobjc/app/AgentLearningCompiler.m\nobjc/app/AgentSessionController.m\nobjc/app/OverlayWindow.m\nobjc/app/ZiYanAppSelector.h\nobjc/app/ZiYanAppSelector.m\nobjc/app/ZiYanDumpManager.m\nobjc/app/ZiYanHomeViewController.m\nobjc/app/ZiYanLLMSidecarClient.h\nobjc/app/ZiYanLLMSidecarClient.m\nobjc/app/ZiYanLiveVisionLearn.m\nobjc/app/ZiYanPageEntryMinimize.h\nobjc/app/ZiYanScriptGenerator.m\nobjc/app/ceshiAppDelegate.m\nobjc/app/ceshiRootViewController.h\nobjc/app/ceshiRootViewController.m\nobjc/app/main.m\nobjc/shared/ZiYanColorMatch.m\nobjc/shared/ZiYanFrameResident.m\nobjc/shared/ZiYanPaths.h\nobjc/shared/ZiYanScriptRunner.m\nobjc/tweak/apptouch/ZiYanAppTouch.m\ntools/test_game_entry_contract.py\ntools/test_game_entry_lease_runner_contract.py'
  full_app_snapshot_revision='5624bc4c08297061d42cdf6f9024868e6acbc2ab'
  # This child only routes explicit user stop through the existing
  # AgentSessionController cleanup path; it does not alter framecap or
  # GameEntry behavior.  Keep the delta explicit so the builder cannot
  # become an arbitrary source-overlay path.
  expected_full_app_stop_fix_delta="$expected_full_app_snapshot_delta"
  full_app_stop_fix_revision='b67e6a5969b68194b183d591265fd7f0acabd294'
  [ "$actual_sidecar_delta" = "$expected_sidecar_delta" ] ||
  [ "$actual_sidecar_delta" = "$expected_diagnostic_delta" ] ||
  { [ "$SOURCE_REVISION" = "$lease_runner_revision" ] &&
    [ "$actual_sidecar_delta" = "$expected_lease_runner_delta" ]; } || {
    { [ "$SOURCE_REVISION" = "$home_command_revision" ] &&
      [ "$actual_sidecar_delta" = "$expected_home_command_delta" ]; } || {
      { [ "$SOURCE_REVISION" = "$full_app_snapshot_revision" ] &&
        [ "$actual_sidecar_delta" = "$expected_full_app_snapshot_delta" ]; } || {
        { [ "$SOURCE_REVISION" = "$full_app_stop_fix_revision" ] &&
          [ "$actual_sidecar_delta" = "$expected_full_app_stop_fix_delta" ]; } || {
        echo "APP_BUILD=FAIL reason=source_delta_not_approved_candidate_scope" >&2
        exit 2
        }
      }
    }
  }
fi
SOURCE_TREE="$(git show -s --format=%T "$SOURCE_REVISION")"
INPUT_ROOT="$(python3 - "$D1_ROOTFUL_DEB" <<'PY'
from pathlib import Path
import sys
# The existing D1 evidence keeps its immutable input freeze beside the
# isolated source worktrees; accept that fixed evidence only.
candidate = Path(sys.argv[1]).resolve()
for parent in [candidate, *candidate.parents]:
    probe = parent / "input_freeze" / "inputs"
    if probe.is_dir():
        print(probe)
        break
else:
    raise SystemExit("d1_input_freeze_not_found")
PY
)"
[ -d "$INPUT_ROOT/vendor/lua-5.3.5" ] &&
[ -d "$INPUT_ROOT/vendor/ncnn-ios" ] &&
[ -e "$INPUT_ROOT/.theos/build_session" ] || {
  echo "APP_BUILD=FAIL reason=d1_immutable_input_freeze_incomplete" >&2
  exit 2
}

APP_WORK_ROOT="$OUT_DIR/worktrees"
mkdir -p "$APP_WORK_ROOT"
WT_A="$APP_WORK_ROOT/rootful_a"
WT_B="$APP_WORK_ROOT/rootful_b"
for wt in "$WT_A" "$WT_B"; do
  [ ! -e "$wt" ] || {
    echo "APP_BUILD=FAIL reason=worktree_path_already_exists path=$wt" >&2
    exit 2
  }
  git worktree add --detach "$wt" "$SOURCE_REVISION"
  for dep in vendor/lua-5.3.5 vendor/ncnn-ios .theos/build_session; do
    src="$INPUT_ROOT/$dep"
    dst="$wt/$dep"
    mkdir -p "$(dirname "$dst")"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      cp -a "$src" "$dst"
    else
      cp -p "$src" "$dst"
    fi
  done
  git -C "$wt" status --porcelain
done

# The two worktrees are the independent rootful builds.  They are then
# re-created from the same immutable revision for the independent rootless
# pair, preventing a scheme's object directory from contaminating another.
WT_C="$APP_WORK_ROOT/rootless_a"
WT_D="$APP_WORK_ROOT/rootless_b"
for wt in "$WT_C" "$WT_D"; do
  git worktree add --detach "$wt" "$SOURCE_REVISION"
  for dep in vendor/lua-5.3.5 vendor/ncnn-ios .theos/build_session; do
    src="$INPUT_ROOT/$dep"
    dst="$wt/$dep"
    mkdir -p "$(dirname "$dst")"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      cp -a "$src" "$dst"
    else
      cp -p "$src" "$dst"
    fi
  done
  git -C "$wt" status --porcelain
done

build_pair() {
  local scheme="$1" first="$2" second="$3" report="$4"
  local canonical_root="$OUT_DIR/canonical_build_paths"
  local canonical_source="$canonical_root/${scheme}_source"
  local -a args=(ZiYan ZiYanAppTouch FINALPACKAGE=1)
  [ "$scheme" = rootless ] && args+=(THEOS_PACKAGE_SCHEME=rootless)
  mkdir -p "$canonical_root"
  for wt in "$first" "$second"; do
    # Theos hashes its effective project path into object tags and linker
    # inputs. A symlink is insufficient because ld still receives physical
    # worktree paths, so materialize each detached source snapshot at one fixed
    # physical path before building.
    python3 - "$canonical_source" "$wt" <<'PY'
from pathlib import Path
import shutil
import sys

link, target = map(Path, sys.argv[1:])
if link.exists() or link.is_symlink():
    if link.is_symlink() or not link.is_dir():
        raise SystemExit(f"canonical_build_path_invalid:{link}")
    shutil.rmtree(link)
link.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(target, link, symlinks=True)
PY
    /bin/bash -c '
      set -euo pipefail
      cd -P "$1"
      {
        printf "CANONICAL_PHYSICAL_PWD=%s\n" "$(pwd -P)"
        test "$(git rev-parse --verify HEAD)" = "$3"
        test -z "$(git status --porcelain --untracked-files=no)"
        make clean >/dev/null 2>&1 || true
        make -B "${@:4}"
      } >"$2" 2>&1
    ' _ "$canonical_source" "$OUT_DIR/${scheme}_$(basename "$wt")_build.log" \
      "$SOURCE_REVISION" "${args[@]}"
    test -s "$(find "$canonical_source/.theos/obj" -type f -path '*/ZiYan.app/ZiYan' \
      ! -path '*/.dSYM/*' -print -quit)"
    test -s "$(find "$canonical_source/.theos/obj" -type f -name ZiYanAppTouch.dylib \
      ! -path '*/.dSYM/*' -print -quit)"
    artifact_suffix="$(basename "$wt" | sed 's/.*_//')"
    app="$(find "$canonical_source/.theos/obj" -type f -path '*/ZiYan.app/ZiYan' \
      ! -path '*/.dSYM/*' -print -quit)"
    touch="$(find "$canonical_source/.theos/obj" -type f -name ZiYanAppTouch.dylib \
      ! -path '*/.dSYM/*' -print -quit)"
    cp -f "$app" "$OUT_DIR/${scheme}_build_${artifact_suffix}_ZiYan"
    cp -f "$touch" "$OUT_DIR/${scheme}_build_${artifact_suffix}_ZiYanAppTouch.dylib"
  done
  first_app="$OUT_DIR/${scheme}_build_a_ZiYan"
  second_app="$OUT_DIR/${scheme}_build_b_ZiYan"
  first_touch="$OUT_DIR/${scheme}_build_a_ZiYanAppTouch.dylib"
  second_touch="$OUT_DIR/${scheme}_build_b_ZiYanAppTouch.dylib"
  mkdir -p "$OUT_DIR/${scheme}_staged"
  cp -f "$first_app" "$OUT_DIR/${scheme}_staged/ZiYan"
  cp -f "$first_touch" "$OUT_DIR/${scheme}_staged/ZiYanAppTouch.dylib"
  python3 "$ROOT/tools/zy_p3_d1_binary_compat.py" \
    --frozen "$OUT_DIR/${scheme}_build_a_ZiYan" \
    --rebuilt "$OUT_DIR/${scheme}_build_b_ZiYan" \
    --source-revision "$SOURCE_REVISION" \
    --evidence-date 20260827 --require-reproducible-sections --out "$report"
  python3 "$ROOT/tools/zy_p3_d1_binary_compat.py" \
    --frozen "$OUT_DIR/${scheme}_build_a_ZiYanAppTouch.dylib" \
    --rebuilt "$OUT_DIR/${scheme}_build_b_ZiYanAppTouch.dylib" \
    --source-revision "$SOURCE_REVISION" \
    --evidence-date 20260827 --require-reproducible-sections \
    --out "${report%.json}_apptouch.json"
}

build_pair rootful "$WT_A" "$WT_B" "$OUT_DIR/rootful_ZiYan_repro.json"
build_pair rootless "$WT_C" "$WT_D" "$OUT_DIR/rootless_ZiYan_repro.json"

# Package only the app/tweak/Lua layer on top of the already verified D1
# package.  The exact changed list is checked below and framecap drift fails.
mkdir -p "$OUT_DIR/packages"
RF_OUT="$OUT_DIR/packages/com.ziyan.ziyan_${RELEASE_ID}_iphoneos-arm.deb"
RL_OUT="$OUT_DIR/packages/com.ziyan.ziyan_${RELEASE_ID}_iphoneos-arm64.deb"
python3 "$ROOT/tools/zy_p3_candidate_package.py" build \
  --base "$D1_ROOTFUL_DEB" --out "$RF_OUT" --release-id "$RELEASE_ID" \
  --replace "$OUT_DIR/rootful_staged/ZiYan" \
  --replace "$OUT_DIR/rootful_staged/ZiYanAppTouch.dylib" \
  --replace "$WT_A/lua/modules/AI.lua" \
  --add "usr/lib/ziyan/lib/lua/modules/GameEntry.lua=$WT_A/lua/modules/GameEntry.lua" \
  --allow Applications/ZiYan.app/ZiYan \
  --allow Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib \
  --allow usr/lib/ziyan/lib/lua/modules/AI.lua \
  --allow usr/lib/ziyan/lib/lua/modules/GameEntry.lua \
  --manifest "$RF_OUT.manifest.json"
python3 "$ROOT/tools/zy_p3_candidate_package.py" build \
  --base "$D1_ROOTLESS_DEB" --out "$RL_OUT" --release-id "$RELEASE_ID" \
  --replace "$OUT_DIR/rootless_staged/ZiYan" \
  --replace "$OUT_DIR/rootless_staged/ZiYanAppTouch.dylib" \
  --replace "$WT_C/lua/modules/AI.lua" \
  --add "usr/lib/ziyan/lib/lua/modules/GameEntry.lua=$WT_C/lua/modules/GameEntry.lua" \
  --allow Applications/ZiYan.app/ZiYan \
  --allow Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib \
  --allow usr/lib/ziyan/lib/lua/modules/AI.lua \
  --allow usr/lib/ziyan/lib/lua/modules/GameEntry.lua \
  --manifest "$RL_OUT.manifest.json"

python3 "$ROOT/tools/zy_p3_candidate_package.py" verify --manifest "$RF_OUT.manifest.json"
python3 "$ROOT/tools/zy_p3_candidate_package.py" verify --manifest "$RL_OUT.manifest.json"
python3 - "$RF_OUT.manifest.json" "$RL_OUT.manifest.json" <<'PY'
import json
import sys
from pathlib import Path

expected = {
    "Applications/ZiYan.app/ZiYan",
    "Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib",
    "usr/lib/ziyan/lib/lua/modules/AI.lua",
    "usr/lib/ziyan/lib/lua/modules/GameEntry.lua",
}
for value in sys.argv[1:]:
    data = json.loads(Path(value).read_text(encoding="utf-8"))
    changed = {str(item).lstrip("/") for item in data.get("changed_payloads", [])}
    normalized = {item.split("var/jb/", 1)[-1] for item in changed}
    if normalized != expected:
        raise SystemExit(f"app_candidate_payload_allowlist_mismatch:{value}:{sorted(normalized)}")
    if any("framecap" in item.lower() for item in normalized):
        raise SystemExit(f"framecap_payload_drift:{value}")
PY
bash "$ROOT/tools/verify_package_install_names.sh" "$RF_OUT"
bash "$ROOT/tools/verify_package_install_names.sh" "$RL_OUT"

python3 - "$OUT_DIR" "$SOURCE_REVISION" "$GAMEENTRY_BASE_REVISION" "$SOURCE_TREE" "$RELEASE_ID" \
  "$RF_OUT" "$RL_OUT" "$D1_ROOTFUL_DEB" "$D1_ROOTLESS_DEB" \
  "$D1_ROOTFUL_SHA256" "$D1_ROOTLESS_SHA256" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
revision, gameentry_base, tree, release_id, rf, rl, d1rf, d1rl, d1rfsha, d1rlsha = sys.argv[2:]
def digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()
def file_record(path: Path) -> dict[str, object]:
    return {"path": str(path), "sha256": digest(str(path)), "size": path.stat().st_size}

data = {
    "schema_version": 1,
    "kind": "ziyan_p3_gameentry_app_candidate",
    "release_id": release_id,
    "source_revision": revision,
    "gameentry_base_revision": gameentry_base,
    "source_tree": tree,
    "source_attestation": "APP_GAMEENTRY_BASE_WITH_SIDECAR_REMOVAL_ONLY",
    "historical_d1_framecap_attested": False,
    "base_d1_release_id": "P3_D1_DUALFRAME_LEASE_20260827",
    "base_d1_rootful": file_record(Path(d1rf)),
    "base_d1_rootless": file_record(Path(d1rl)),
    "base_d1_declared_sha256": {"rootful": d1rfsha, "rootless": d1rlsha},
    "candidate_rootful": file_record(Path(rf)),
    "candidate_rootless": file_record(Path(rl)),
    "payload_allowlist": [
        "Applications/ZiYan.app/ZiYan",
        "Library/MobileSubstrate/DynamicLibraries/ZiYanAppTouch.dylib",
        "usr/lib/ziyan/lib/lua/modules/AI.lua",
        "usr/lib/ziyan/lib/lua/modules/GameEntry.lua",
    ],
    "framecap_payload_policy": "UNCHANGED_FROM_D1_BASE",
    "rollback": {
        "rootful_deb": d1rf,
        "rootless_deb": d1rl,
        "rootful_sha256": d1rfsha,
        "rootless_sha256": d1rlsha,
    },
    "worktrees": [str(out / "worktrees" / name)
                  for name in ("rootful_a", "rootful_b", "rootless_a", "rootless_b")],
}
(out / "app_candidate_provenance.json").write_text(
    json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

cat >"$OUT_DIR/APP_CANDIDATE_RELEASE.env" <<EOF
APP_CANDIDATE_RELEASE_ID='$RELEASE_ID'
APP_CANDIDATE_SOURCE_REVISION='$SOURCE_REVISION'
APP_CANDIDATE_GAMEENTRY_BASE_REVISION='$GAMEENTRY_BASE_REVISION'
APP_CANDIDATE_SOURCE_TREE='$SOURCE_TREE'
APP_CANDIDATE_ROOTFUL_DEB='$RF_OUT'
APP_CANDIDATE_ROOTLESS_DEB='$RL_OUT'
APP_CANDIDATE_ROOTFUL_SHA256='$(shasum -a 256 "$RF_OUT" | awk '{print $1}')'
APP_CANDIDATE_ROOTLESS_SHA256='$(shasum -a 256 "$RL_OUT" | awk '{print $1}')'
APP_CANDIDATE_ATTESTATION='APP_GAMEENTRY_BASE_WITH_SIDECAR_REMOVAL_ONLY'
APP_CANDIDATE_HISTORICAL_D1_FRAME_CAP_ATTESTED='false'
APP_CANDIDATE_FRAMECAP_POLICY='UNCHANGED_FROM_D1_BASE'
APP_CANDIDATE_ROLLBACK_ROOTFUL='$D1_ROOTFUL_DEB'
APP_CANDIDATE_ROLLBACK_ROOTLESS='$D1_ROOTLESS_DEB'
EOF

echo "APP_BUILD=PASS"
echo "APP_RELEASE_ID=$RELEASE_ID"
echo "APP_SOURCE_REVISION=$SOURCE_REVISION"
echo "APP_EVIDENCE=$OUT_DIR"
echo "APP_ROOTFUL=$RF_OUT"
echo "APP_ROOTLESS=$RL_OUT"
