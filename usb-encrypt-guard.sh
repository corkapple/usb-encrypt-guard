#!/bin/bash
#
# usb-encrypt-guard.sh
#
# Runs as root from a LaunchDaemon (StartOnMount). When an unencrypted external
# USB volume is mounted it:
#   1. immediately remounts the volume read-only,
#   2. asks the logged-in user (osascript dialog) to encrypt it, eject it,
#      or keep it read-only.
#
# Phones (iPhone, Android MTP/PTP) never mount as disks, so they never show up here.
#
# Modes:
#   (no args)          scan mounted volumes and handle new unencrypted ones
#   --status           print what the script sees for every mounted /Volumes disk
#   --handle <devnode> (internal) interactive handler for one volume
#
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

### ------------------------------ Configuration ------------------------------
VERSION="5"
ORG_TITLE="IT Security"
ALLOWED_BUS="USB"                 # pipe-separated BusProtocol values, e.g. "USB|Secure Digital"
MIN_PASSWORD_LENGTH=8
DIALOG_TIMEOUT=900                # seconds before a dialog gives up (= keep read-only)
ALLOW_ERASE_NONAPFS="yes"         # "no" = exFAT/FAT/NTFS drives can only be ejected or kept read-only
                                  # (use "no" if users share drives with Windows machines)
STATE_DIR="/private/var/db/usb-encrypt-guard"
LOG_FILE="/var/log/usb-encrypt-guard.log"
LOCK_DIR="/private/var/run/usb-encrypt-guard.lock"
### ---------------------------------------------------------------------------

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# --- plist helpers -----------------------------------------------------------
dinfo() { /usr/sbin/diskutil info -plist "$1" 2>/dev/null; }
pget()  { /usr/bin/plutil -extract "$2" raw -o - - <<<"$1" 2>/dev/null; }

# For APFS volumes the bus protocol / whole disk live on the physical store.
physical_info() {
  local x fs store
  x=$(dinfo "$1")
  fs=$(pget "$x" FilesystemType)
  if [[ "$fs" == "apfs" ]]; then
    store=$(pget "$x" APFSPhysicalStores.0.APFSPhysicalStore)
    [[ -n "$store" ]] && x=$(dinfo "/dev/$store")
  fi
  printf '%s' "$x"
}

bus_allowed() {
  local b IFS='|'
  for b in $ALLOWED_BUS; do [[ "$1" == "$b" ]] && return 0; done
  return 1
}

# Second opinion from `diskutil apfs list`, in case `diskutil info` field names differ
# between macOS versions.
apfs_list_encrypted() {   # arg: device identifier, e.g. disk5s1
  local id="$1" xml nc nv i j p
  xml=$(/usr/sbin/diskutil apfs list -plist 2>/dev/null)
  nc=$(pget "$xml" Containers); [[ "$nc" =~ ^[0-9]+$ ]] || return 1
  for ((i=0; i<nc; i++)); do
    nv=$(pget "$xml" "Containers.$i.Volumes"); [[ "$nv" =~ ^[0-9]+$ ]] || continue
    for ((j=0; j<nv; j++)); do
      p="Containers.$i.Volumes.$j"
      if [[ "$(pget "$xml" "$p.DeviceIdentifier")" == "$id" ]]; then
        [[ "$(pget "$xml" "$p.FileVault")" == "true" || "$(pget "$xml" "$p.Encryption")" == "true" ]]
        return
      fi
    done
  done
  return 1
}

is_encrypted() {   # args: devnode, diskutil info plist of the volume
  [[ "$(pget "$2" Encryption)" == "true" || "$(pget "$2" FileVault)" == "true" ]] && return 0
  [[ "$(pget "$2" FilesystemType)" == "apfs" ]] && apfs_list_encrypted "${1#/dev/}"
}

list_mounts() {    # prints: devnode <TAB> mountpoint <TAB> options
  local line re='^(/dev/disk[0-9]+(s[0-9]+)+) on (/Volumes/.+) \(([^)]*)\)$'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    fi
  done < <(/sbin/mount)
}

lock_readonly() {  # devnode mountpoint options
  [[ "$3" == *read-only* ]] && return 0
  if /usr/sbin/diskutil unmount "$1" >/dev/null 2>&1; then
    /usr/sbin/diskutil mount readOnly "$1" >/dev/null 2>&1 \
      && log "remounted $1 read-only" || log "ERROR: could not remount $1 read-only"
  elif /sbin/mount -u -o rdonly "$2" >/dev/null 2>&1; then
    log "updated $2 to read-only in place"
  else
    log "ERROR: could not make $1 read-only (busy?)"
  fi
}

# --- status mode -------------------------------------------------------------
status() {
  local dev mp opts info pinfo
  printf '%-14s %-8s %-16s %-10s %-10s %s\n' DEVICE FS BUS ENCRYPTED INTERNAL MOUNTPOINT
  while IFS=$'\t' read -r dev mp opts; do
    info=$(dinfo "$dev"); pinfo=$(physical_info "$dev")
    printf '%-14s %-8s %-16s %-10s %-10s %s\n' "$dev" "$(pget "$info" FilesystemType)" \
      "$(pget "$pinfo" BusProtocol)" \
      "enc=$(pget "$info" Encryption)/fv=$(pget "$info" FileVault)" \
      "$(pget "$pinfo" Internal)" "$mp"
  done < <(list_mounts)
}

# --- scan mode ---------------------------------------------------------------
scan() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  # single instance; drop stale lock after 2 minutes
  [[ -d "$LOCK_DIR" && -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +2 2>/dev/null)" ]] && rmdir "$LOCK_DIR" 2>/dev/null
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

  local dev mp opts info pinfo bus uuid whole present=" "
  while IFS=$'\t' read -r dev mp opts; do
    pinfo=$(physical_info "$dev")
    bus=$(pget "$pinfo" BusProtocol)
    bus_allowed "$bus" || continue
    [[ "$(pget "$pinfo" Internal)" == "true" ]] && continue

    info=$(dinfo "$dev")
    uuid=$(pget "$info" VolumeUUID); [[ -z "$uuid" ]] && uuid="${dev#/dev/}"
    whole=$(pget "$pinfo" ParentWholeDisk)
    present+="$uuid "

    if is_encrypted "$dev" "$info"; then rm -f "$STATE_DIR/$uuid"; continue; fi
    [[ -e "$STATE_DIR/busy.$whole" ]] && continue   # user-approved encrypt/erase running
    [[ -e "$STATE_DIR/$uuid" ]] && continue          # already handled this connection

    : > "$STATE_DIR/$uuid"
    log "[v$VERSION] unencrypted external volume: $dev ($mp) fs=$(pget "$info" FilesystemType) bus=$bus uuid=$uuid"
    lock_readonly "$dev" "$mp" "$opts"
    "$SELF" --handle "$dev" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null
  done < <(list_mounts)

  # forget volumes that are no longer connected, so reconnecting prompts again
  local f base
  for f in "$STATE_DIR"/*; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f")
    [[ "$base" == busy.* ]] && continue
    [[ "$present" == *" $base "* ]] || rm -f "$f"
  done
}

# --- interactive handler -----------------------------------------------------
CUSER=""; CUID=""
find_console_user() {
  CUSER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
  [[ -n "$CUSER" && "$CUSER" != "root" && "$CUSER" != "loginwindow" ]] || return 1
  CUID=$(/usr/bin/id -u "$CUSER") || return 1
}

# run AppleScript in the user's GUI session
ask_user() { /bin/launchctl asuser "$CUID" /usr/bin/sudo -u "$CUSER" /usr/bin/osascript -e "$1" 2>>"$LOG_FILE"; }

esc() { printf '%s' "$1" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g'; }

info_dialog() {  # message [icon]
  ask_user "display dialog \"$(esc "$1")\" with title \"$ORG_TITLE\" buttons {\"OK\"} default button \"OK\" with icon ${2:-note} giving up after 60" >/dev/null
}

get_password() {  # name -> prints password on success
  local name="$1" p1 p2 tries=0
  while (( tries < 3 )); do
    tries=$((tries+1))
    p1=$(ask_user "text returned of (display dialog \"Choose a password for the drive \\\"$(esc "$name")\\\".\\n\\nYou need it every time you connect the drive. IT cannot recover it if you forget it.\" default answer \"\" with hidden answer with title \"$ORG_TITLE\" buttons {\"Cancel\",\"OK\"} default button \"OK\" with icon note giving up after $DIALOG_TIMEOUT)") || return 1
    p2=$(ask_user "text returned of (display dialog \"Enter the password again to confirm.\" default answer \"\" with hidden answer with title \"$ORG_TITLE\" buttons {\"Cancel\",\"OK\"} default button \"OK\" with icon note giving up after $DIALOG_TIMEOUT)") || return 1
    if [[ "$p1" != "$p2" ]]; then
      info_dialog "The passwords did not match. Please try again." caution; continue
    fi
    if (( ${#p1} < MIN_PASSWORD_LENGTH )); then
      info_dialog "The password must be at least $MIN_PASSWORD_LENGTH characters long." caution; continue
    fi
    printf '%s' "$p1"; return 0
  done
  return 1
}

encrypt_volume() {  # devnode password
  local dev="$1" pw="$2"
  # make sure it is mounted read/write for the in-place conversion
  /usr/sbin/diskutil unmount "$dev" >/dev/null 2>&1
  /usr/sbin/diskutil mount "$dev" >/dev/null 2>&1
  printf '%s' "$pw" | /usr/sbin/diskutil apfs encryptVolume "$dev" -user disk -stdinpassphrase >>"$LOG_FILE" 2>&1
}

handle() {
  local dev="$1" info pinfo fs name uuid whole safe msg btn pw confirm newdev i
  mkdir -p "$STATE_DIR"
  info=$(dinfo "$dev"); pinfo=$(physical_info "$dev")
  fs=$(pget "$info" FilesystemType); name=$(pget "$info" VolumeName)
  uuid=$(pget "$info" VolumeUUID); [[ -z "$uuid" ]] && uuid="${dev#/dev/}"
  whole=$(pget "$pinfo" ParentWholeDisk)
  [[ -z "$name" ]] && name="USB drive"

  if ! find_console_user; then
    log "no console user; leaving $dev read-only, will retry"
    rm -f "$STATE_DIR/$uuid"; return
  fi

  if [[ "$fs" == "apfs" ]]; then
    msg="The USB drive \\\"$(esc "$name")\\\" is not encrypted.\\n\\nCompany policy requires USB drives to be encrypted before you can save files to them. Until then the drive is read-only.\\n\\nEncrypt it now? Your files are kept and encryption continues in the background."
    btn=$(ask_user "button returned of (display dialog \"$msg\" with title \"$ORG_TITLE\" buttons {\"Eject\",\"Keep read-only\",\"Encrypt drive\"} default button \"Encrypt drive\" with icon caution giving up after $DIALOG_TIMEOUT)")
  elif [[ "$ALLOW_ERASE_NONAPFS" != "yes" ]]; then
    msg="The USB drive \\\"$(esc "$name")\\\" is not encrypted and uses the $fs format.\\n\\nCompany policy requires USB drives to be encrypted before you can save files to them. This drive is read-only; you can still copy files off it.\\n\\nContact $ORG_TITLE if you need to use this drive for writing."
    btn=$(ask_user "button returned of (display dialog \"$msg\" with title \"$ORG_TITLE\" buttons {\"Eject\",\"Keep read-only\"} default button \"Keep read-only\" with icon caution giving up after $DIALOG_TIMEOUT)")
  else
    msg="The USB drive \\\"$(esc "$name")\\\" is not encrypted and uses the $fs format, which cannot be encrypted in place.\\n\\nCompany policy requires USB drives to be encrypted before you can save files to them. Until then the drive is read-only, so you can still copy files OFF it.\\n\\nTo use it you must ERASE the whole drive and re-create it as an encrypted drive. ALL DATA ON IT WILL BE LOST.\\n\\nNote: encrypted drives can only be used on Macs."
    btn=$(ask_user "button returned of (display dialog \"$msg\" with title \"$ORG_TITLE\" buttons {\"Eject\",\"Keep read-only\",\"Erase and encrypt\"} default button \"Keep read-only\" with icon stop giving up after $DIALOG_TIMEOUT)")
  fi

  case "$btn" in
    "Eject")
      log "user chose eject for $dev"
      /usr/sbin/diskutil eject "/dev/$whole" >/dev/null 2>&1 ;;

    "Encrypt drive")
      pw=$(get_password "$name") || { log "password entry cancelled for $dev"; rm -f "$STATE_DIR/$uuid"; return; }
      : > "$STATE_DIR/busy.$whole"
      log "encrypting $dev in place"
      if encrypt_volume "$dev" "$pw"; then
        log "encryption started for $dev"
        info_dialog "Encryption of \"$name\" has started. You can use the drive normally; it finishes in the background. Keep the drive connected until it completes." note
      else
        log "ERROR: encryptVolume failed for $dev"
        info_dialog "Encrypting \"$name\" failed. The drive stays read-only. Contact IT if this keeps happening." stop
      fi
      pw=""; rm -f "$STATE_DIR/busy.$whole" ;;

    "Erase and encrypt")
      confirm=$(ask_user "text returned of (display dialog \"This will permanently erase the ENTIRE drive \\\"$(esc "$name")\\\", including every volume on it.\\n\\nType ERASE to continue.\" default answer \"\" with title \"$ORG_TITLE\" buttons {\"Cancel\",\"Erase\"} default button \"Cancel\" with icon stop giving up after $DIALOG_TIMEOUT)")
      if [[ "$confirm" != "ERASE" ]]; then
        log "erase not confirmed for $dev"; rm -f "$STATE_DIR/$uuid"; return
      fi
      pw=$(get_password "$name") || { log "password entry cancelled for $dev"; rm -f "$STATE_DIR/$uuid"; return; }
      : > "$STATE_DIR/busy.$whole"
      safe=$(printf '%s' "$name" | /usr/bin/tr -cd '[:alnum:] _-'); [[ -z "$safe" ]] && safe="Encrypted USB"
      log "erasing /dev/$whole as encrypted APFS ($safe)"
      if /usr/sbin/diskutil eraseDisk APFS "$safe" GPT "/dev/$whole" >>"$LOG_FILE" 2>&1; then
        newdev=""
        for i in 1 2 3 4 5 6 7 8 9 10; do
          newdev=$(pget "$(dinfo "/Volumes/$safe")" DeviceIdentifier)
          [[ -n "$newdev" ]] && break; sleep 1
        done
        if [[ -n "$newdev" ]] && encrypt_volume "/dev/$newdev" "$pw"; then
          log "erase + encrypt done for /dev/$newdev"
          info_dialog "\"$safe\" has been erased and is now encrypted." note
        else
          log "ERROR: could not encrypt the new volume on /dev/$whole"
          info_dialog "The drive was erased but could not be encrypted. It will be read-only until it is encrypted. Contact IT." stop
        fi
      else
        log "ERROR: eraseDisk failed for /dev/$whole"
        info_dialog "Erasing the drive failed. Nothing was changed." stop
      fi
      pw=""; rm -f "$STATE_DIR/busy.$whole" ;;

    *)
      log "user kept $dev read-only (button='${btn}')" ;;
  esac
}

# --- main --------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
case "${1:-}" in
  --status) status ;;
  --handle) handle "${2:?devnode required}" ;;
  *)        scan ;;
esac
exit 0
