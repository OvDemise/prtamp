#!/bin/bash
# Project Reclaimer for AMP - download Halo 3 files from Steam with SteamCMD.
#
# Downloads only the Halo 3 depots of Halo: The Master Chief Collection (app 976730)
# instead of the whole ~136 GB collection, then hard-links them into the server's
# game/ folder. The Steam account must own MCC.
#
# Usage: project-reclaimergamefiles.sh <root dir> <base dir> <username> [password] [guard code] [campaign: true|false] [base depot: true|false]
#
# Normal path: the update stage before this one is AMP's own SteamCMD stage, so AMP shows its
# Steam sign-in and Steam Guard prompt in the web panel. This script then reuses that saved
# sign-in through AMP's SteamCMD (<root dir>/steamcmd.sh) and passes only the username.
# Fallback (no AMP SteamCMD found): installs its own SteamCMD with its sign-in under <root dir>/.steam-home.

set -uo pipefail

ROOT="${1%/}"
BASE="${2%/}"
STEAM_USER="${3:-}"
STEAM_PASS="${4:-}"
GUARD_CODE="${5:-}"
WITH_CAMPAIGN="${6:-true}"
WITH_BASE="${7:-false}"

APP=976730
DEPOT_H3_MP=976739        # MCC - H3: Multiplayer Depot   (~6.9 GB download)
DEPOT_H3_CAMPAIGN=976738  # MCC - H3: Campaign Depot      (~6.9 GB) campaign.map, 040_voi.map, 050_floodvoi.map
DEPOT_MCC_BASE=976731     # MCC - Base Depot              (~9.7 GB) only if halo3.dll isn't in the H3 depots

GAME="$BASE/game"
if [ -x "$ROOT/steamcmd.sh" ]; then
  SC_DIR="$ROOT"                      # AMP's SteamCMD: shares the sign-in from AMP's Steam prompt
  AMP_STEAMCMD=1
else
  SC_DIR="$ROOT/steamcmd"
  export HOME="$ROOT/.steam-home"     # own SteamCMD keeps its sign-in inside the instance
  AMP_STEAMCMD=0
fi

log() { echo "[Halo 3 files] $*"; }
fail() { echo "[Halo 3 files] ERROR: $*" >&2; exit 1; }

[ -n "$STEAM_USER" ] || fail "Set 'Steam Username' (Halo 3 Files) to an account that owns Halo: The Master Chief Collection."
mkdir -p "$SC_DIR" "$GAME" || fail "Could not create folders under $ROOT"
[ "$AMP_STEAMCMD" = 1 ] || mkdir -p "$HOME" || fail "Could not create $HOME"

# 1. SteamCMD
if [ ! -x "$SC_DIR/steamcmd.sh" ]; then
  log "Installing SteamCMD (AMP's own SteamCMD wasn't found)"
  wget -q -O "$SC_DIR/steamcmd_linux.tar.gz" https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    || fail "Could not download SteamCMD"
  tar -xzf "$SC_DIR/steamcmd_linux.tar.gz" -C "$SC_DIR" && rm -f "$SC_DIR/steamcmd_linux.tar.gz" \
    || fail "Could not unpack SteamCMD"
fi

# 2. Build the SteamCMD command
DEPOTS=("$DEPOT_H3_MP")
[ "$WITH_CAMPAIGN" = "true" ] && DEPOTS+=("$DEPOT_H3_CAMPAIGN")
[ "$WITH_BASE" = "true" ] && DEPOTS+=("$DEPOT_MCC_BASE")

ARGS=(+@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +@sSteamCmdForcePlatformType windows)
if [ -n "$STEAM_PASS" ] && [ -n "$GUARD_CODE" ]; then
  ARGS+=(+login "$STEAM_USER" "$STEAM_PASS" "$GUARD_CODE")   # code from the Steam Mobile app or email
elif [ -n "$STEAM_PASS" ]; then
  ARGS+=(+login "$STEAM_USER" "$STEAM_PASS")
else
  ARGS+=(+login "$STEAM_USER")       # cached sign-in from an earlier run
fi
for d in "${DEPOTS[@]}"; do ARGS+=(+download_depot "$APP" "$d"); done
ARGS+=(+quit)

if [ -n "$STEAM_PASS" ]; then log "Signing in as $STEAM_USER and downloading depots: ${DEPOTS[*]}"
else log "Using the saved Steam sign-in for $STEAM_USER; downloading depots: ${DEPOTS[*]}"; fi
# Credentials are passed as arguments, never echoed. stdin is closed so a prompt fails instead of hanging:
# an unattended update can't answer Steam Guard, so a code must be supplied or a sign-in already saved.
OUT="$ROOT/steamcmd_gamefiles.log"
timeout 7200 "$SC_DIR/steamcmd.sh" "${ARGS[@]}" </dev/null 2>&1 | tee "$OUT" | grep -v -i "password"
RC=${PIPESTATUS[0]}

if grep -q -i -E "Invalid Password|Login Failure|InvalidPassword|RateLimit" "$OUT"; then
  fail "Steam sign-in failed. Check username/password; if Steam emailed you a Steam Guard code, put it in 'Steam Guard Code' and run Update again within a few minutes."
fi
if grep -q -i -E "Two-factor|Steam Guard code|account logon denied|need two-factor" "$OUT"; then
  fail "Steam wants a Steam Guard code: the saved sign-in is missing or expired. Run Update again and sign in when AMP asks."
fi
if grep -q -i -E "Cached credentials not found|No cached credentials|password:" "$OUT"; then
  fail "No saved Steam sign-in for $STEAM_USER. Check that 'Steam Username' matches the account you signed in with when AMP asked, then run Update again."
fi
if grep -q -i -E "Depot download failed|Missing configuration|No subscription|access denied" "$OUT"; then
  fail "Steam refused a depot. The account must own Halo: The Master Chief Collection. See $OUT"
fi
[ "$RC" -eq 0 ] || fail "SteamCMD exited with code $RC. See $OUT"

# 3. Link the depots into game/
for d in "${DEPOTS[@]}"; do
  SRC=$(find "$SC_DIR/linux32" "$SC_DIR/steamapps" "$HOME/Steam" "$HOME/.steam" "$HOME/.local/share/Steam" -maxdepth 6 -type d -name "depot_$d" -path "*app_$APP*" 2>/dev/null | head -n1)
  [ -n "$SRC" ] || fail "Downloaded depot $d not found under $SC_DIR or $HOME"
  log "Linking depot $d into game/ ($SRC)"
  cp -alf "$SRC/." "$GAME/" 2>/dev/null || cp -af "$SRC/." "$GAME/" || fail "Could not copy depot $d into $GAME"
done

# 4. Sanity check
if [ ! -f "$GAME/halo3/halo3.dll" ]; then
  fail "game/halo3/halo3.dll is missing. Turn on 'Include MCC Base Depot' and run Update again."
fi
[ -f "$GAME/halo3/maps/shared.map" ] || log "WARNING: game/halo3/maps/shared.map not found"
if [ "$WITH_CAMPAIGN" = "true" ]; then
  for m in campaign.map 040_voi.map; do
    [ -f "$GAME/halo3/maps/$m" ] || log "WARNING: game/halo3/maps/$m not found (Forge campaign vehicles/AI need it)"
  done
fi

rm -f "$OUT.prev"; mv -f "$OUT" "$OUT.prev" 2>/dev/null
log "Done. Halo 3 files are in $GAME"
exit 0
