#!/usr/bin/env bash

set -euo pipefail

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
ask() {
	local y
	for ((n = 0; n < 3; n++)); do
		pr "$1 [y/n]"
		if read -r y; then
			case "$y" in
			y) return 0 ;;
			n) return 1 ;;
			esac
		fi
		pr "Asking again..."
	done
	return 1
}

repo=$(cd "$(dirname "$0")" && pwd)
cd "$repo"
if [ ! -f build.sh ] || [ ! -f config.toml ]; then
	echo >&2 "Run build-termux.sh from a patched-kushion checkout."
	exit 1
fi

pr "Ask for storage permission"
until
	yes | termux-setup-storage >/dev/null 2>&1
	ls /sdcard >/dev/null 2>&1
do sleep 1; done

setup_marker=~/.patched_kushion_"$(date '+%Y%m')"
if [ ! -f "$setup_marker" ]; then
	pr "Setting up environment..."
	yes "" | pkg update -y
	pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
	pkg install -y git curl jq openjdk-21 zip
	: >"$setup_marker"
fi

output_dir=~/storage/downloads/patched-kushion
mkdir -p "$output_dir"
[ -f "$output_dir/config.toml" ] || cp config.toml "$output_dir/config.toml"

printf "\n"
until
	if ask "Open config.toml to configure builds?"; then
		am start -a android.intent.action.VIEW \
			-d file:///sdcard/Download/patched-kushion/config.toml -t text/plain
	fi
	ask "Setup is done. Start building?"
do :; done

cp -f "$output_dir/config.toml" config.toml
./build.sh

for artifact in build/*; do
	[ -e "$artifact" ] || {
		echo >&2 "No build outputs were produced."
		exit 1
	}
	mv -f "$artifact" "$output_dir/"
done

pr "Outputs are available in /sdcard/Download/patched-kushion"
am start -a android.intent.action.VIEW \
	-d file:///sdcard/Download/patched-kushion -t resource/folder
