#!/bin/bash
# Removes usb-encrypt-guard. Run as root.
LABEL="com.organization.usb-encrypt-guard"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null
/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist" \
           /usr/local/libexec/usb-encrypt-guard.sh
/bin/rm -rf /private/var/db/usb-encrypt-guard /private/var/run/usb-encrypt-guard.lock
echo "usb-encrypt-guard removed (log kept at /var/log/usb-encrypt-guard.log)"
