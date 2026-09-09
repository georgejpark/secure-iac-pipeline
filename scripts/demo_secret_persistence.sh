#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# LIVE DEMO: why deleting a secret from git does not remove it.
#
# Builds a throwaway repo in a temp directory, commits a credential, then
# applies the three fixes every team reaches for -- delete the file, add it to
# .gitignore, add encryption -- and shows the original is still retrievable
# after all three.
#
# Safe to run anywhere. Touches only its own temp directory, and the
# credential is synthetic and assembled at runtime, so no secret literal is ever committed
# to THIS repository.
#
#   ./scripts/demo_secret_persistence.sh
# ---------------------------------------------------------------------------
set -euo pipefail

BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
step() { printf "\n${BOLD}%s${RST}\n" "$1"; }
run()  { printf "${DIM}\$ %s${RST}\n" "$*"; eval "$@"; }
pause(){ [[ -n "${DEMO_NOPAUSE:-}" ]] || { printf "\n${DIM}-- enter to continue --${RST}"; read -r; }; }
# Finite source + cut, so nothing receives SIGPIPE under `set -o pipefail`.
randstr(){ openssl rand -base64 $(( $1 * 3 )) | LC_ALL=C tr -dc "A-Za-z0-9" | cut -c1-"$1"; }
randupper(){ openssl rand -hex $(( $1 * 2 )) | LC_ALL=C tr "a-f" "A-F" | cut -c1-"$1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# Assembled at runtime, never stored as a literal in the repo.
FAKE_KEY="EXAMPLEKEY$(randupper 10)"
FAKE_SEC="$(randstr 40)"

step "SETUP  a repository that looks like every repository"
run "git init -q demo"
cd demo
git config user.email "demo@example.com"; git config user.name "Demo"

cat > .env <<EOF
DATABASE_URL=postgresql://claims_app:$(randstr 18)@db.internal:5432/claims
AWS_ACCESS_KEY_ID=${FAKE_KEY}
AWS_SECRET_ACCESS_KEY=${FAKE_SEC}
JWT_SIGNING_KEY=$(randstr 44)
EOF
echo "app running" > app.py
run "git add -A && git commit -q -m 'Add local dev config' && echo committed"
LEAK_COMMIT=$(git rev-parse --short HEAD)
printf "  ${RED}A credential is now in history at commit %s${RST}\n" "$LEAK_COMMIT"
pause

step "FIX 1  delete the file  ${DIM}(the instinct)${RST}"
run "git rm -q --cached .env && rm .env"
run "git commit -q -m 'Remove .env from version control' && echo done"
printf "  Working tree: ${GRN}%s${RST}\n" "$([[ -f .env ]] && echo '.env still present' || echo 'no .env present')"
pause

step "FIX 2  add it to .gitignore  ${DIM}(the hygiene step)${RST}"
echo ".env" > .gitignore
run "git add .gitignore && git commit -q -m 'Ignore .env' && echo done"
pause

step "FIX 3  add encryption  ${DIM}(the thorough step -- a real team did exactly this)${RST}"
cat > encrypt_env.sh <<'ENC'
#!/usr/bin/env bash
# Encrypt .env before it ever goes near git.
openssl enc -aes-256-cbc -salt -in .env -out .env.enc -pass env:ENV_PASSPHRASE
ENC
chmod +x encrypt_env.sh
run "git add encrypt_env.sh && git commit -q -m 'Add utility for encrypting/decrypting .env files' && echo done"
printf "  ${GRN}Three fixes applied. The repo now looks correct by every review standard.${RST}\n"
pause

step "THE PROBLEM"
printf "  Current files: ${GRN}%s${RST}\n" "$(git ls-files | tr '\n' ' ')"
printf "  ${DIM}No .env anywhere. A scan of the current tree reports this repo CLEAN.${RST}\n\n"
printf "  ${BOLD}But the blob was never deleted -- only unreferenced from the tip:${RST}\n\n"
run "git show ${LEAK_COMMIT}:.env"
printf "\n  ${RED}${BOLD}Every credential is still retrievable. One command. No special access.${RST}\n"
pause

step "AND IT SURVIVES A CLONE"
cd "$WORK"; run "git clone -q demo cloned"
cd cloned
printf "  Fresh clone, working tree: ${GRN}%s${RST}\n" "$(git ls-files | tr '\n' ' ')"
run "git log --all --diff-filter=A --format='%h %s' -- .env"
printf "  ${RED}The leak travels with every clone, every fork, every CI cache.${RST}\n"
pause

step "WHAT ACTUALLY WORKS"
cat <<EOF
  ${BOLD}1. Rotate first.${RST} Assume it is compromised. History rewriting takes
     time and coordination; revoking the credential takes minutes. Rotate,
     then clean up. Never the other way round.

  ${BOLD}2. Rewrite history.${RST}   git filter-repo --path .env --invert-paths
     Then force-push and ask the platform team to run garbage collection.
     Forks, open PR refs and existing clones still hold the blob.

  ${BOLD}3. Prevent the next one.${RST}
     - pre-commit gitleaks hook, so it never reaches a commit
     - CI gitleaks with ${YEL}fetch-depth: 0${RST}, so history is scanned, not just the tip
     - a .gitignore in the FIRST commit of every repository

  ${DIM}The order matters. Rotation is the only step that reduces risk today.${RST}
EOF
printf "\n${BOLD}${GRN}Demo complete.${RST} ${DIM}Temp directory removed on exit.${RST}\n\n"
