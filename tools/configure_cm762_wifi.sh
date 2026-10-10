#!/bin/bash
set -euo pipefail

SD_DEVICE=${1:-/dev/rdisk7}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

if [[ "$(uname -s)" != Darwin ]] || ! command -v diskutil >/dev/null 2>&1; then
	echo "This command currently requires macOS and diskutil." >&2
	exit 1
fi
case "$SD_DEVICE" in
	/dev/rdisk*) ;;
	*) echo "Use a raw macOS disk path such as /dev/rdisk7." >&2; exit 1 ;;
esac
DISK_DEVICE=${SD_DEVICE/rdisk/disk}
if [[ ! -e "$SD_DEVICE" ]]; then
	echo "SD device $SD_DEVICE is not available; no changes were made." >&2
	exit 1
fi

PARTITION_DEVICE="${DISK_DEVICE}s2"
if [[ ! -e "$PARTITION_DEVICE" ]]; then
	echo "Root filesystem partition $PARTITION_DEVICE is not available; no changes were made." >&2
	exit 1
fi

E2FS_PREFIX=""
if command -v brew >/dev/null 2>&1; then
	E2FS_PREFIX=$(brew --prefix e2fsprogs 2>/dev/null || true)
fi
E2FSCK="${E2FS_PREFIX:+$E2FS_PREFIX/sbin/}e2fsck"
DEBUGFS="${E2FS_PREFIX:+$E2FS_PREFIX/sbin/}debugfs"
E2UNDO="${E2FS_PREFIX:+$E2FS_PREFIX/sbin/}e2undo"
if [[ ! -x "$E2FSCK" || ! -x "$DEBUGFS" || ! -x "$E2UNDO" ]]; then
	echo "e2fsprogs with e2fsck, debugfs, and e2undo is required (on macOS: brew install e2fsprogs)." >&2
	exit 1
fi

read -r -p "Wi-Fi SSID: " SSID
read -r -s -p "Wi-Fi password (input hidden): " PASSPHRASE
printf '\n'
if [[ -z "$SSID" ]]; then
	echo "SSID must not be empty." >&2
	exit 1
fi

umask 077
TEMP_DIR=$(mktemp -d /private/var/tmp/cm762-wifi.XXXXXX)
WIFI_CONFIG="$TEMP_DIR/wpa_supplicant.conf"
WIFI_INIT_SCRIPT="$TEMP_DIR/S41cm762-network"
UNDO_FILE="$TEMP_DIR/ext4.undo"
COMMAND_FILE="$TEMP_DIR/debugfs.commands"
DEBUGFS_OUTPUT="$TEMP_DIR/debugfs.out"
DEBUGFS_ERROR="$TEMP_DIR/debugfs.err"
DEBUGFS_CHECK_CONFIG="$TEMP_DIR/check.conf"
DEBUGFS_CHECK_INIT="$TEMP_DIR/check.init"
DEBUGFS_CHECK_ERROR="$TEMP_DIR/check.err"
DISK_UNMOUNTED=0
DISK_EJECTED=0
MUTATION_STARTED=0
MUTATION_COMMITTED=0

cleanup() {
	status=$?
	trap - EXIT
	if [[ "$MUTATION_STARTED" -eq 1 && "$MUTATION_COMMITTED" -eq 0 && -s "$UNDO_FILE" ]]; then
		echo "Wi-Fi file update did not complete; restoring its ext4 changes with the undo log." >&2
		sudo "$E2UNDO" "$UNDO_FILE" "$PARTITION_DEVICE" >/dev/null 2>&1 || \
			echo "WARNING: automatic rollback failed; do not boot the card before checking $PARTITION_DEVICE." >&2
	fi
	if [[ "$DISK_UNMOUNTED" -eq 1 && "$DISK_EJECTED" -eq 0 ]]; then
		sync
		if [[ "$status" -eq 0 ]]; then
			diskutil eject "$DISK_DEVICE" >/dev/null 2>&1 || true
		else
			echo "The card remains inserted but unmounted; you can retry without reinserting it." >&2
		fi
	fi
	rm -rf "$TEMP_DIR"
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

diskutil unmountDisk force "$DISK_DEVICE"
DISK_UNMOUNTED=1

printf '%s\n%s\n' "$SSID" "$PASSPHRASE" | python3 tools/make_wpa_supplicant_config.py > "$WIFI_CONFIG"
unset PASSPHRASE
cp "$ROOT/package/cm762-wifi/S41cm762-network" "$WIFI_INIT_SCRIPT"
chmod 0600 "$WIFI_CONFIG"

# Work against the unmounted ext4 partition itself. First allow e2fsck to
# replay the journal and preen-repair safe metadata issues. A read-only -n pass
# skips journal recovery, which can report stale counters/orphan state as errors.
echo "Checking and safely repairing the unmounted root filesystem on $PARTITION_DEVICE..."
set +e
sudo "$E2FSCK" -p "$PARTITION_DEVICE"
FSCK_STATUS=$?
set -e
if (( FSCK_STATUS > 1 )); then
	echo "e2fsck could not safely repair the filesystem (exit status $FSCK_STATUS); no Wi-Fi files were changed." >&2
	exit 1
fi

echo "Verifying the filesystem is clean before editing..."
if ! sudo "$E2FSCK" -fn "$PARTITION_DEVICE"; then
	echo "The filesystem still has errors after safe repair; no Wi-Fi files were changed." >&2
	exit 1
fi

for target in /etc/wpa_supplicant.conf /etc/init.d/S41cm762-network; do
	stat_output=$(sudo "$DEBUGFS" -R "stat $target" "$PARTITION_DEVICE" 2>&1) || {
		echo "Could not inspect $target on $PARTITION_DEVICE; no changes were made." >&2
		exit 1
	}
	if ! grep -q '^Inode:' <<<"$stat_output"; then
		echo "Expected file $target was not found on $PARTITION_DEVICE; no changes were made." >&2
		exit 1
	fi
done

cat > "$COMMAND_FILE" <<EOF
rm /etc/wpa_supplicant.conf
write $WIFI_CONFIG /etc/wpa_supplicant.conf
set_inode_field /etc/wpa_supplicant.conf uid 0
set_inode_field /etc/wpa_supplicant.conf gid 0
set_inode_field /etc/wpa_supplicant.conf mode 0100600
rm /etc/init.d/S41cm762-network
write $WIFI_INIT_SCRIPT /etc/init.d/S41cm762-network
set_inode_field /etc/init.d/S41cm762-network uid 0
set_inode_field /etc/init.d/S41cm762-network gid 0
set_inode_field /etc/init.d/S41cm762-network mode 0100755
EOF

MUTATION_STARTED=1
set +e
sudo "$DEBUGFS" -w -z "$UNDO_FILE" -f "$COMMAND_FILE" "$PARTITION_DEVICE" \
	>"$DEBUGFS_OUTPUT" 2>"$DEBUGFS_ERROR"
DEBUGFS_STATUS=$?
set -e
if (( DEBUGFS_STATUS != 0 )) || grep -qiE "File not found|Ext2 file already exists|Couldn.t|error" "$DEBUGFS_OUTPUT" "$DEBUGFS_ERROR"; then
	cat "$DEBUGFS_OUTPUT" "$DEBUGFS_ERROR" >&2
	echo "debugfs failed while updating the card (exit status $DEBUGFS_STATUS)." >&2
	exit 1
fi

if ! sudo "$DEBUGFS" -R 'cat /etc/wpa_supplicant.conf' "$PARTITION_DEVICE" \
	>"$DEBUGFS_CHECK_CONFIG" 2>"$DEBUGFS_CHECK_ERROR"; then
	cat "$DEBUGFS_CHECK_ERROR" >&2
	echo "Could not read back /etc/wpa_supplicant.conf from the ext4 filesystem." >&2
	exit 1
fi
if ! cmp -s "$WIFI_CONFIG" "$DEBUGFS_CHECK_CONFIG"; then
	expected_size=$(wc -c < "$WIFI_CONFIG" | tr -d ' ')
	actual_size=$(wc -c < "$DEBUGFS_CHECK_CONFIG" | tr -d ' ')
	first_diff=$(cmp -l "$WIFI_CONFIG" "$DEBUGFS_CHECK_CONFIG" | awk 'NR == 1 { print $1; exit }' || true)
	echo "Read-back of /etc/wpa_supplicant.conf differs (expected ${expected_size} bytes, read ${actual_size}; first differing byte ${first_diff:-after end})." >&2
	exit 1
fi
if ! sudo "$DEBUGFS" -R 'cat /etc/init.d/S41cm762-network' "$PARTITION_DEVICE" \
	>"$DEBUGFS_CHECK_INIT" 2>"$DEBUGFS_CHECK_ERROR"; then
	cat "$DEBUGFS_CHECK_ERROR" >&2
	echo "Could not read back /etc/init.d/S41cm762-network from the ext4 filesystem." >&2
	exit 1
fi
if ! cmp -s "$WIFI_INIT_SCRIPT" "$DEBUGFS_CHECK_INIT"; then
	expected_size=$(wc -c < "$WIFI_INIT_SCRIPT" | tr -d ' ')
	actual_size=$(wc -c < "$DEBUGFS_CHECK_INIT" | tr -d ' ')
	first_diff=$(cmp -l "$WIFI_INIT_SCRIPT" "$DEBUGFS_CHECK_INIT" | awk 'NR == 1 { print $1; exit }' || true)
	echo "Read-back of /etc/init.d/S41cm762-network differs (expected ${expected_size} bytes, read ${actual_size}; first differing byte ${first_diff:-after end})." >&2
	exit 1
fi

if ! CONFIG_STAT=$(sudo "$DEBUGFS" -R 'stat /etc/wpa_supplicant.conf' "$PARTITION_DEVICE" 2>&1); then
	echo "Could not inspect /etc/wpa_supplicant.conf metadata:" >&2
	printf '%s\n' "$CONFIG_STAT" >&2
	exit 1
fi
if ! INIT_STAT=$(sudo "$DEBUGFS" -R 'stat /etc/init.d/S41cm762-network' "$PARTITION_DEVICE" 2>&1); then
	echo "Could not inspect /etc/init.d/S41cm762-network metadata:" >&2
	printf '%s\n' "$INIT_STAT" >&2
	exit 1
fi
if ! grep -Eq 'Mode:[[:space:]]+0600' <<<"$CONFIG_STAT" ||
   ! grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' <<<"$CONFIG_STAT"; then
	echo "The WPA config file ownership or mode is not root:root 0600." >&2
	printf '%s\n' "$CONFIG_STAT" >&2
	exit 1
fi
if ! grep -Eq 'Mode:[[:space:]]+0755' <<<"$INIT_STAT" ||
   ! grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' <<<"$INIT_STAT"; then
	echo "The network startup service ownership or mode is not root:root 0755." >&2
	printf '%s\n' "$INIT_STAT" >&2
	exit 1
fi

echo "Verifying the updated ext4 filesystem..."
set +e
sudo "$E2FSCK" -fn "$PARTITION_DEVICE"
FSCK_STATUS=$?
set -e
if (( FSCK_STATUS != 0 )); then
	echo "Post-update filesystem check failed (e2fsck exit status $FSCK_STATUS)." >&2
	exit 1
fi
sync
MUTATION_COMMITTED=1

diskutil eject "$DISK_DEVICE"
DISK_EJECTED=1
echo "Wi-Fi config written directly to $PARTITION_DEVICE; it will connect automatically on boot."
