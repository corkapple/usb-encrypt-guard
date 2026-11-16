#!/bin/bash
# Builds a single self-contained installer (for an Intune macOS shell script) that
# embeds usb-encrypt-guard.sh and the LaunchDaemon plist.
set -euo pipefail
cd "$(dirname "$0")"
OUT="install-usb-encrypt-guard.sh"
LABEL="com.organization.usb-encrypt-guard"

{
cat <<'HEAD'
#!/bin/bash
# Self-contained installer for usb-encrypt-guard. Run as root (Intune runs scripts as root by default).
set -e
[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }
HEAD
echo "LABEL=\"$LABEL\""
cat <<'MID'
/bin/mkdir -p /usr/local/libexec
/usr/bin/base64 -D > /usr/local/libexec/usb-encrypt-guard.sh <<'EOF_SCRIPT'
MID
base64 < usb-encrypt-guard.sh
echo "EOF_SCRIPT"
echo "/usr/bin/base64 -D > \"/Library/LaunchDaemons/\$LABEL.plist\" <<'EOF_PLIST'"
base64 < "$LABEL.plist"
echo "EOF_PLIST"
cat <<'TAIL'
/usr/sbin/chown root:wheel /usr/local/libexec/usb-encrypt-guard.sh "/Library/LaunchDaemons/$LABEL.plist"
/bin/chmod 755 /usr/local/libexec/usb-encrypt-guard.sh
/bin/chmod 644 "/Library/LaunchDaemons/$LABEL.plist"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
echo "usb-encrypt-guard installed"
TAIL
} > "$OUT"
chmod +x "$OUT"
echo "built $OUT"
