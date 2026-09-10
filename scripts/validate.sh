#!/usr/bin/env bash
# validate.sh - everything that can be checked from the Proxmox host.
# Run it the morning of the demo. Every line should say PASS.

PASS=0; FAIL=0
ok(){ printf "  \033[32mPASS\033[0m  %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  \033[31mFAIL\033[0m  %s  <- %s\n" "$1" "$2"; FAIL=$((FAIL+1)); }
hdr(){ printf "\n\033[1m%s\033[0m\n" "$1"; }

APPS="301:app-dev-1:10.10.10.20:dev 311:app-stage-1:10.20.10.20:stage 321:app-prod-1:10.30.10.20:prod 322:app-prod-2:10.30.10.21:prod"
GREET="Hello World, Hello Guys This is George and nice to meet you"

hdr "1. Infrastructure"
n=$(pct list | tail -n +2 | wc -l)
[ "$n" -eq 8 ] && ok "8 containers exist" || no "container count" "found $n"
r=$(pct list | tail -n +2 | grep -c running)
[ "$r" -eq 8 ] && ok "all 8 running" || no "all running" "only $r"
pct list | grep -q " 323 \|^323" && no "VMID 323 free" "something is using it" || ok "VMID 323 free for the demo"

hdr "2. Each application answers"
for a in $APPS; do
  IFS=: read -r V N IP E <<< "$a"
  curl -s --max-time 5 "http://$IP:8080/health" 2>/dev/null | grep -q '"ok"' \
    && ok "$N health" || no "$N health" "no answer on $IP"
done

hdr "3. Each application says the greeting, with its own identity"
for a in $APPS; do
  IFS=: read -r V N IP E <<< "$a"
  B=$(curl -s --max-time 5 "http://$IP:8080/" 2>/dev/null)
  echo "$B" | grep -q "$GREET" || { no "$N greeting" "wrong or missing text"; continue; }
  echo "$B" | grep -q "\"host\": \"$N\""       || { no "$N hostname" "does not report $N"; continue; }
  echo "$B" | grep -q "\"environment\": \"$E\"" || { no "$N environment" "does not report $E"; continue; }
  ok "$N greeting, host=$N env=$E"
done

hdr "4. Version, service account, restart on boot"
for a in $APPS; do
  IFS=: read -r V N IP E <<< "$a"
  curl -s --max-time 5 "http://$IP:8080/version" 2>/dev/null | grep -q '"1.1.0"' \
    && ok "$N running 1.1.0" || no "$N version" "not 1.1.0"
  U=$(pct exec "$V" -- ps -eo user,args 2>/dev/null | grep "[a]pp.py" | awk '{print $1}' | head -1)
  [ "$U" = rapta ] && ok "$N runs as rapta, not root" || no "$N service account" "running as '$U'"
  [ "$(pct exec "$V" -- systemctl is-enabled inspection-service 2>/dev/null)" = enabled ] \
    && ok "$N restarts after reboot" || no "$N on-boot" "not enabled"
done

hdr "5. Both releases on disk, so rollback is a symlink move"
for a in $APPS; do
  IFS=: read -r V N IP E <<< "$a"
  pct exec "$V" -- test -d /opt/rapta/inspection/releases/1.0.0 \
    && pct exec "$V" -- test -d /opt/rapta/inspection/releases/1.1.0 \
    && ok "$N holds 1.0.0 and 1.1.0" || no "$N releases" "a release is missing"
done

hdr "6. Environments cannot reach each other"
for p in "301:10.20.10.20:dev->stage" "301:10.30.10.20:dev->prod" \
         "311:10.10.10.20:stage->dev" "311:10.30.10.20:stage->prod" \
         "321:10.10.10.20:prod->dev" "321:10.20.10.20:prod->stage"; do
  IFS=: read -r V T L <<< "$p"
  pct exec "$V" -- ping -c1 -W2 "$T" >/dev/null 2>&1 \
    && no "$L blocked" "IT GOT THROUGH" || ok "$L blocked"
done

hdr "7. Development cannot open production's secrets"
pct exec 201 -- test -f /tmp/prod.enc.yaml 2>/dev/null || \
  pct push 201 /root/secure-iac-pipeline/terraform/envs/prod/secrets.enc.yaml /tmp/prod.enc.yaml --perms 644 2>/dev/null
pct exec 201 -- su - runner -c \
  "SOPS_AGE_KEY_FILE=/home/runner/.config/sops/age/keys.txt sops --decrypt /tmp/prod.enc.yaml" 2>&1 \
  | grep -q "no master key" && ok "dev cannot decrypt prod secrets" || no "SOPS isolation" "it decrypted"

hdr "8. Right password, wrong network, still refused"
PW=$(pct exec 204 -- cat /root/creds/prod.pw 2>/dev/null)
pct exec 201 -- bash -c "PGPASSWORD='$PW' psql -h 10.40.10.10 -U tf_prod -d tfstate_prod -c 'SELECT 1'" 2>&1 \
  | grep -q "no pg_hba.conf entry" && ok "dev refused by prod database" || no "database isolation" "it connected"

hdr "9. The deploy step is staged and safe to repeat"
[ -x /root/install-app.sh ] && ok "install-app.sh present" || no "install-app.sh" "missing"
m=""
for f in app.py requirements.txt VERSION inspection-service.service; do
  [ -f "/opt/app-source/$f" ] || m="$m $f"
done
[ -z "$m" ] && ok "app source staged" || no "app source" "missing:$m"
/root/install-app.sh prod 2>&1 | grep -q "installing" \
  && no "re-run skips healthy servers" "it reinstalled" || ok "re-run skips healthy servers"

printf "\n\033[1m%d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
