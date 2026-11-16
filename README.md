# usb-encrypt-guard

Enforces encryption of external USB drives on managed macOS devices, without depending on an EDR product.

When an **unencrypted external USB volume** is mounted, the script remounts it **read-only** and shows the logged-in user a prompt. Writing is only possible after the drive is encrypted.

## How it works

1. A root LaunchDaemon runs `usb-encrypt-guard.sh` on every mount (`StartOnMount`) and every 120 seconds as a fallback.
2. Only external volumes on the USB bus are considered (configurable). Internal disks, disk images and phones are ignored. iPhones and MTP/PTP Android phones never mount as disks, so they are unaffected.
3. Encrypted volumes are left alone.
4. An unencrypted volume is remounted read-only immediately, then the user gets a dialog (via `osascript`):

| Drive format | Choices |
|---|---|
| APFS (unencrypted) | **Encrypt drive** (in place, files are kept, user chooses a password), Eject, Keep read-only |
| exFAT / FAT / NTFS / HFS+ | **Erase and encrypt** (wipes the whole drive, user must type `ERASE`; result is APFS, Mac-only), Eject, Keep read-only |

5. If the dialog is ignored or closed, the drive stays read-only. The prompt returns when the drive is reconnected.

## Files

| File | Purpose |
|---|---|
| `usb-encrypt-guard.sh` | The guard script (installed to `/usr/local/libexec/`) |
| `com.organization.usb-encrypt-guard.plist` | LaunchDaemon definition |
| `build-installer.sh` | Builds the single-file installer from the two files above |
| `install-usb-encrypt-guard.sh` | Self-contained installer (generated; deploy this via Intune) |
| `uninstall-usb-encrypt-guard.sh` | Removes the daemon, script and state |

## Configuration

Edit the variables at the top of `usb-encrypt-guard.sh`, then run `./build-installer.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `ORG_TITLE` | `IT Security` | Title of the dialogs and name shown to users |
| `ALLOWED_BUS` | `USB` | Pipe-separated bus types, e.g. `USB\|Secure Digital` to include SD card readers |
| `MIN_PASSWORD_LENGTH` | `8` | Minimum password length when encrypting |
| `DIALOG_TIMEOUT` | `900` | Seconds before a dialog gives up (drive stays read-only) |
| `ALLOW_ERASE_NONAPFS` | `yes` | `no` = exFAT/FAT/NTFS drives can only be ejected or kept read-only. Use `no` if users share drives with Windows machines |

The LaunchDaemon label `com.organization.usb-encrypt-guard` is a placeholder. If you change it, change it in the plist filename, `build-installer.sh` (`LABEL=`) and `uninstall-usb-encrypt-guard.sh`.

## Deploying with Intune

1. Run `./build-installer.sh` (creates `install-usb-encrypt-guard.sh`).
2. In Intune: **Devices > macOS > Scripts > Add**, upload `install-usb-encrypt-guard.sh`.
3. Run script as signed-in user: **No** (must run as root).
4. Script frequency: **every 1 hour** (recommended). The installer is idempotent and re-installs the daemon if it was stopped or removed.
5. Assign to the target device group.

Manual install for testing: `sudo bash install-usb-encrypt-guard.sh`

## Verifying and troubleshooting

```bash
# What does the script see for every mounted volume?
sudo /usr/local/libexec/usb-encrypt-guard.sh --status

# Log (script version appears as [vN] in the scan lines; osascript errors are logged too)
sudo tail -30 /var/log/usb-encrypt-guard.log

# Is the daemon loaded?
sudo launchctl print system/com.organization.usb-encrypt-guard

# Forget handled volumes (prompt again on next scan)
sudo rm -f /private/var/db/usb-encrypt-guard/*

# Temporarily stop enforcement on a test Mac
sudo launchctl bootout system/com.organization.usb-encrypt-guard
```

Test matrix before wide rollout: encrypted APFS (no action), unencrypted APFS, exFAT, FAT32, NTFS, SD card reader; on Sonoma and Sequoia, Intel and Apple Silicon.

## Limitations

- **Reactive, not preventive.** The drive is writable for a moment between mounting and the read-only remount. For a true pre-write block, use a device control product (for example Microsoft Defender device control with the `encryption: apfs` clause) alongside this.
- **Not tamper-proof against local admins.** Root can stop the daemon. Mitigate by removing standard-user admin rights, running the installer on a schedule from Intune, and monitoring daemon status.
- **No key escrow.** The user's password is the only key. Intune's FileVault recovery key escrow covers the startup disk only, not external volumes. If recovery is required, the script needs to generate and escrow a passphrase (for example to Azure Key Vault).
- **APFS-only encryption.** Encrypted drives are Mac-only. Windows users sharing drives will need `ALLOW_ERASE_NONAPFS="no"` or another workflow.
- Dialogs are English-only.
- Encryption detection uses `diskutil info -plist` (`Encryption`, `FileVault`) with `diskutil apfs list -plist` as a fallback; verify with `--status` on each macOS version you support.

## Uninstall

```bash
sudo bash uninstall-usb-encrypt-guard.sh
```
