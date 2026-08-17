#!/usr/bin/env bash
# P4: 验证 Memory* 已实现的 plist 缓存语义，不读取或修改第三方进程地址。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set +u
PASS="$ZY_SSH_PASS"; [ -n "$PASS" ] || PASS=alpine
WANT="$1"; [ -n "$WANT" ] || WANT=all
set -u
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/MEMORY_CACHE_CONTRACT_$STAMP"
mkdir -p "$OUT"
PASS_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no"
KEY_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes"
AUTH=""

init_auth() {
  local ip="$1"
  if sshpass -p "$PASS" ssh $PASS_OPTS "root@$ip" true >/dev/null 2>&1; then AUTH=password
  elif ssh -n $KEY_OPTS "root@$ip" true >/dev/null 2>&1; then AUTH=key
  else echo "FATAL ssh_auth_failed ip=$ip" >&2; return 1
  fi
  echo "SSH_AUTH=$AUTH ip=$ip"
}

ssh_r() {
  local ip="$1"; shift
  if [ "$AUTH" = password ]; then sshpass -p "$PASS" ssh $PASS_OPTS "root@$ip" "$@"
  else ssh -n $KEY_OPTS "root@$ip" "$@"
  fi
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" var=/usr/lib/ziyan/var
  [ "$scheme" = rootless ] && var=/var/jb/usr/lib/ziyan/var
  local media=/private/var/mobile/Media/ZiYan bid=com.ziyan.contract.memory.$tag value=ziyan_mem_$STAMP-$tag
  echo "==== MEMORY_CACHE .$tag ===="
  init_auth "$ip"
  ssh_r "$ip" "VAR='$var' MEDIA='$media' BID='$bid' VALUE='$value' bash -s" <<'EOS' | tee "$OUT/gate_$tag.txt"
set +e
mkdir -p "$VAR" "$MEDIA"
echo ts=1 >"$VAR/.ziyan_kill_scripts"; sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_active" "$MEDIA/_memory_contract_out.txt" "$VAR/memory/$BID.plist"
echo 1 >"$VAR/.ziyan_embed_on"
cat >"$MEDIA/_memory_contract.lua" <<LUA
function main()
  local out = "$MEDIA/_memory_contract_out.txt"
  local function w(s) local f=io.open(out,"a"); if f then f:write(tostring(s)); f:write(string.char(10)); f:close() end end
  local bid, value = "$BID", "$VALUE"
  local a = type(MemoryWrite)=="function" and MemoryWrite(bid,"alpha",value)
  local b = type(MemoryWrite)=="function" and MemoryWrite(bid,"beta","42")
  local ra = type(MemoryAccess)=="function" and MemoryAccess(bid,"alpha") or ""
  local rc = type(MemoryAccess)=="function" and MemoryAccess(bid,"ALPHA") or ""
  local k = type(MemoryKeys)=="function" and MemoryKeys(bid) or {}
  local d = type(MemoryDump)=="function" and MemoryDump(bid,10) or {}
  local inv = nil
  if type(MemoryWrite)=="function" then inv=MemoryWrite("","","x") end
  local function ex(cmd) local a,b,c=os.execute(cmd); return tostring(a)..":"..tostring(b)..":"..tostring(c) end
  local function hk(n) for _,v in ipairs((k and k.keys) or {}) do if tostring(v)==n then return true end end return false end
  local function hi(n,v0) for _,v in ipairs((d and d.items) or {}) do if tostring(v.key)==n and tostring(v.value)==v0 then return true end end return false end
  w("WRITE_A="..tostring(a)); w("WRITE_B="..tostring(b)); w("READ_A="..tostring(ra)); w("READ_CI="..tostring(rc))
  w("KEY_A="..tostring(hk("alpha"))); w("KEY_B="..tostring(hk("beta"))); w("DUMP_A="..tostring(hi("alpha",value))); w("DUMP_B="..tostring(hi("beta","42"))); w("INVALID="..tostring(inv))
  w("HAS_WRITE="..tostring(type(MemoryWrite)=="function")); w("EXEC_TRUE="..ex("true")); w("EXEC_ROOTFUL_PY="..ex("/usr/lib/ziyan/bin/python3 -c 'import plistlib'")); w("EXEC_ROOTLESS_PY="..ex("/var/jb/usr/lib/ziyan/bin/python3 -c 'import plistlib'")); w("done")
end
LUA
chmod 666 "$MEDIA/_memory_contract.lua"
{ echo "path=$MEDIA/_memory_contract.lua"; echo stop=0; } >"$VAR/.ziyan_run_intent"
echo "$MEDIA/_memory_contract.lua" >"$VAR/.ziyan_embed_script"
echo "nonce=memory_contract_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" 2>/dev/null
for i in $(seq 1 80); do grep -q '^done$' "$MEDIA/_memory_contract_out.txt" 2>/dev/null && break; sleep 0.25; done
echo ---OUT---
cat "$MEDIA/_memory_contract_out.txt" 2>/dev/null || echo NO_OUT
OK=1
grep -qx 'WRITE_A=true' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx 'WRITE_B=true' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx "READ_A=$VALUE" "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx "READ_CI=$VALUE" "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx 'KEY_A=true' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx 'KEY_B=true' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx 'DUMP_A=true' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx 'DUMP_B=true' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
grep -qx 'INVALID=false' "$MEDIA/_memory_contract_out.txt" 2>/dev/null || OK=0
[ "$OK" = 1 ] && echo VERDICT=PASS || echo VERDICT=FAIL
echo ts=1 >"$VAR/.ziyan_kill_scripts"; sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" "$VAR/.ziyan_active" "$MEDIA/_memory_contract.lua" "$VAR/memory/$BID.plist"
EOS
}

case "$WANT" in
  all) run_one 53 192.168.31.53 rootless; run_one 101 192.168.31.101 rootful; run_one 112 192.168.31.112 rootful; run_one 166 192.168.31.166 rootful ;;
  53) run_one 53 192.168.31.53 rootless ;;
  101) run_one 101 192.168.31.101 rootful ;;
  112) run_one 112 192.168.31.112 rootful ;;
  166) run_one 166 192.168.31.166 rootful ;;
  *) echo "usage: $0 [all|53|101|112|166]"; exit 2 ;;
esac
pass_n=0; fail_n=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  if grep -q '^VERDICT=PASS$' "$f"; then pass_n=$((pass_n+1)); else fail_n=$((fail_n+1)); fi
done
{
  echo "# P4 Memory cache contract"
  echo "stamp=$STAMP want=$WANT"
  echo "scope=MemoryWrite/MemoryAccess/MemoryKeys/MemoryDump cache semantics only"
  echo "PASS_HOSTS=$pass_n FAIL_HOSTS=$fail_n"
  [ "$fail_n" = 0 ] && echo VERDICT=PASS || echo VERDICT=FAIL
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
