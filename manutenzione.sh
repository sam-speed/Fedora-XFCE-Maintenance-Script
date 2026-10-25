#!/usr/bin/env bash
# =====================================================================
# manutenzione.sh - Manutenzione completa per Fedora XFCE
#   1. Snapshot Timeshift (se fallisce: log + spegnimento, niente update)
#   2. Aggiornamento di tutto: dnf, flatpak, firmware, pipx, rustup, npm, snap
#   3. Log dettagliato con orari in /var/log/manutenzione/
#   4. Spegnimento del PC
# Uso: sudo ./manutenzione.sh   (se lanciato senza sudo si auto-eleva)
# =====================================================================

# Percorso assoluto dello script (funziona anche con "bash manutenzione.sh")
SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"

# --- Auto-elevazione a root -------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Inserisci la password: dopo questa non serve piu' nulla, puoi andare via."
    exec sudo --preserve-env=DISPLAY bash "$SCRIPT" "$@"
fi

# Impedisce sospensione/standby durante la manutenzione (poi spegne da solo)
if [[ -z "$MANUT_INHIBIT" ]] && command -v systemd-inhibit >/dev/null 2>&1; then
    export MANUT_INHIBIT=1
    exec systemd-inhibit --what=sleep:idle --who="manutenzione" \
        --why="Manutenzione in corso" bash "$SCRIPT" "$@"
fi

# Utente reale (serve per flatpak --user, pipx, rustup, npm...)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

LOG_DIR="/var/log/manutenzione"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/manutenzione_$(date '+%Y-%m-%d_%H-%M-%S').log"
ERRORI=0
LISTA_ERRORI=()

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
log_file_only() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

spegni() {
    log "Spegnimento tra 30 secondi (Ctrl+C per annullare)..."
    sleep 30
    log "Spegnimento ORA."
    systemctl poweroff
    exit 0
}

# Esegue un comando, registra output riga per riga con orario ed esito
run_step() {
    local nome="$1"; shift
    local t0=$SECONDS
    log ">>> INIZIO: $nome"
    log_file_only "    comando: $*"
    "$@" 2>&1 | while IFS= read -r riga; do
        echo "[$(date '+%F %T')]     $riga" >> "$LOG"
    done
    local rc=${PIPESTATUS[0]}
    local dur=$((SECONDS - t0))
    if [[ $rc -eq 0 ]]; then
        log "<<< OK: $nome (${dur}s)"
    else
        log "<<< ERRORE: $nome - codice di uscita $rc (${dur}s)"
        ERRORI=$((ERRORI + 1))
        LISTA_ERRORI+=("$nome (rc=$rc)")
    fi
    return $rc
}

esiste() { command -v "$1" >/dev/null 2>&1; }
come_utente() { sudo -u "$REAL_USER" -H env "PATH=$PATH" "$@"; }

# --- Intestazione -----------------------------------------------------
log "=================================================="
log "MANUTENZIONE AVVIATA - host: $(hostname) - utente: $REAL_USER"
log "Sistema: $(. /etc/os-release && echo "$PRETTY_NAME") - kernel: $(uname -r)"
log "File di log: $LOG"
log "=================================================="

# --- 1. SNAPSHOT TIMESHIFT --------------------------------------------
# SICUREZZA: UUID della partizione dove Timeshift salva gli snapshot.
# Ricavalo con il disco COLLEGATO:   lsblk -f     (colonna UUID)
# Se lasciato vuoto si usa quello presente nella configurazione di Timeshift.
UUID_ATTESO=""

# Funzioni di supporto (snapshot_fallito non ritorna mai: spegne il PC)
snapshot_fallito() {
    log "<<< ERRORE: Snapshot Timeshift NON riuscito: $1"
    log "Aggiornamenti NON eseguiti per sicurezza. Spengo il PC."
    spegni
}

uuid_da_config() {
    local f
    for f in /etc/timeshift/timeshift.json /etc/timeshift.json; do
        if [[ -r "$f" ]]; then
            grep -oP '"backup_device_uuid"\s*:\s*"\K[^"]*' "$f" | head -n1
            return
        fi
    done
}

# Stampa il device (es. /dev/sdb1) se un disco con quell'UUID e' collegato ora
disco_presente() {
    lsblk -rpno NAME,UUID 2>/dev/null | awk -v u="$1" 'tolower($2)==tolower(u){print $1; exit}'
}

# Nomi degli snapshot esistenti (formato AAAA-MM-GG_HH-MM-SS)
elenco_snapshot() {
    timeshift --list </dev/null 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -u
}

log ">>> INIZIO: Snapshot Timeshift"

if ! esiste timeshift; then
    snapshot_fallito "timeshift non installato (sudo dnf install timeshift)"
fi

# 1a. Controlli PRIMA di toccare Timeshift: disco giusto e collegato
UUID_CONFIG="$(uuid_da_config)"
log_file_only "    UUID in configurazione Timeshift: '${UUID_CONFIG:-nessuno}'"
[[ -n "$UUID_CONFIG" ]] || snapshot_fallito "nessun dispositivo di backup configurato in Timeshift"

if [[ -n "$UUID_ATTESO" && "${UUID_ATTESO,,}" != "${UUID_CONFIG,,}" ]]; then
    snapshot_fallito "Timeshift e' configurato su $UUID_CONFIG invece del disco atteso $UUID_ATTESO"
fi

UUID_BACKUP="${UUID_ATTESO:-$UUID_CONFIG}"
DEV_BACKUP="$(disco_presente "$UUID_BACKUP")"
[[ -n "$DEV_BACKUP" ]] || snapshot_fallito "disco di backup (UUID $UUID_BACKUP) non collegato"
log "Disco di backup trovato: $DEV_BACKUP (UUID $UUID_BACKUP)"

SNAP_PRIMA="$(elenco_snapshot)"
log_file_only "    Snapshot esistenti prima: $(printf '%s\n' "$SNAP_PRIMA" | grep -c .)"

# 1b. Creazione snapshot (--scripted: nessuna domanda interattiva)
SNAP_OUT="$(timeshift --create --scripted --comments "Manutenzione $(date '+%F %T')" --tags O </dev/null 2>&1)"
SNAP_RC=$?
while IFS= read -r riga; do log_file_only "    [timeshift] $riga"; done <<< "$SNAP_OUT"

# 1c. Verifiche DOPO: codice di uscita, messaggi di errore, configurazione, nuovo snapshot
[[ $SNAP_RC -eq 0 ]] || snapshot_fallito "timeshift ha restituito codice $SNAP_RC"

SEGNALI="$(grep -iE '^E:|error|fail|not available|no snapshot device|unable|cannot|no space|not enough space|disk full' <<< "$SNAP_OUT")"
if [[ -n "$SEGNALI" ]]; then
    while IFS= read -r r; do log "    [timeshift] $r"; done <<< "$SEGNALI"
    snapshot_fallito "errori nell'output di Timeshift"
fi

UUID_DOPO="$(uuid_da_config)"
if [[ "${UUID_DOPO,,}" != "${UUID_CONFIG,,}" ]]; then
    snapshot_fallito "la configurazione di Timeshift e' cambiata durante l'esecuzione ($UUID_CONFIG -> $UUID_DOPO)"
fi

SNAP_DOPO="$(elenco_snapshot)"
SNAP_NUOVI="$(comm -13 <(printf '%s\n' "$SNAP_PRIMA" | sort -u) <(printf '%s\n' "$SNAP_DOPO" | sort -u) | grep -v '^$')"
[[ -n "$SNAP_NUOVI" ]] || snapshot_fallito "nessun nuovo snapshot presente nell'elenco dopo la creazione"

log "<<< OK: Snapshot Timeshift creato e verificato: $(echo $SNAP_NUOVI)"

# Pulizia cache subito dopo lo snapshot
if esiste dnf; then
    run_step "DNF: pulizia cache (clean all)" dnf clean all
fi

# --- 2. AGGIORNAMENTI -------------------------------------------------

# DNF (pacchetti di sistema)
if esiste dnf; then
    run_step "DNF: aggiornamento pacchetti" dnf upgrade --refresh -y
    run_step "DNF: rimozione dipendenze orfane" dnf autoremove -y
else
    log "SALTATO: dnf non trovato"
fi

# Flatpak (installazione di sistema + utente)
if esiste flatpak; then
    run_step "Flatpak (sistema): aggiornamento" flatpak update --system -y --noninteractive
    run_step "Flatpak (utente $REAL_USER): aggiornamento" come_utente flatpak update --user -y --noninteractive
    run_step "Flatpak (sistema): rimozione runtime inutilizzati" flatpak uninstall --system --unused -y --noninteractive
    run_step "Flatpak (utente): rimozione runtime inutilizzati" come_utente flatpak uninstall --user --unused -y --noninteractive
else
    log "SALTATO: flatpak non trovato"
fi

# Firmware (fwupd)
if esiste fwupdmgr; then
    run_step "Firmware: refresh metadati" fwupdmgr refresh --force
    # rc=2 significa "nessun aggiornamento disponibile": non e' un errore
    log ">>> INIZIO: Firmware: aggiornamenti"
    FW_OUT="$(fwupdmgr update -y --no-reboot-check 2>&1)"; FW_RC=$?
    while IFS= read -r r; do log_file_only "    [fwupd] $r"; done <<< "$FW_OUT"
    if [[ $FW_RC -eq 0 || $FW_RC -eq 2 ]]; then
        log "<<< OK: Firmware (rc=$FW_RC)"
    else
        log "<<< ERRORE: Firmware (rc=$FW_RC)"
        ERRORI=$((ERRORI + 1)); LISTA_ERRORI+=("Firmware (rc=$FW_RC)")
    fi
fi

# Snap (se presente)
if esiste snap; then
    run_step "Snap: aggiornamento" snap refresh
fi

# pipx (utente)
if esiste pipx || [[ -x "$REAL_HOME/.local/bin/pipx" ]]; then
    run_step "pipx: aggiornamento di tutti i pacchetti" come_utente pipx upgrade-all
fi

# rustup (utente)
if [[ -x "$REAL_HOME/.cargo/bin/rustup" ]]; then
    run_step "rustup: aggiornamento toolchain" come_utente "$REAL_HOME/.cargo/bin/rustup" update
fi

# npm globali (solo se installati nella home dell'utente, non nel sistema)
if esiste npm; then
    run_step "npm: aggiornamento pacchetti globali" come_utente npm update -g
fi

# --- 3. RIEPILOGO -----------------------------------------------------
log "=================================================="
if [[ $ERRORI -eq 0 ]]; then
    log "MANUTENZIONE COMPLETATA SENZA ERRORI"
else
    log "MANUTENZIONE COMPLETATA CON $ERRORI ERRORE/I:"
    for e in "${LISTA_ERRORI[@]}"; do log "   - $e"; done
fi

if esiste needs-restarting; then
    if ! needs-restarting -r >/dev/null 2>&1; then
        log "NOTA: e' consigliato un riavvio (kernel/librerie core aggiornati). Lo spegnimento basta."
    fi
fi
log "Log salvato in: $LOG"
log "=================================================="

chown "$REAL_USER":"$REAL_USER" "$LOG" 2>/dev/null

# --- 4. SPEGNIMENTO ---------------------------------------------------
spegni
