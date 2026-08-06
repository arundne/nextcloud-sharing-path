#!/usr/bin/env bash
#
# Builds the release tarballs.
#
# Two app ids are shipped from this single code base:
#
#   sharepath    what the sources declare — our own app id, published on the
#                App Store under this name
#   sharingpath  the original app id, generated as a variant so existing
#                /apps/sharingpath/... URLs can keep working should the original
#                App Store entry ever be transferred to us
#
# The generated variant also gets its own PHP namespace. Both apps can end up
# installed on the same instance (the old sharingpath is still present on
# existing setups), and two apps declaring OCA\SharePath\… would collide in the
# class loader.
#
set -euo pipefail

cd "$(dirname "$0")"

# macOS tar would otherwise store extended attributes as AppleDouble "._name"
# entries and use the pax format, which adds "PaxHeader/…" entries. Both are
# invisible to tar itself but are extracted as real files by Nextcloud's PHP
# extractor, which then rejects the archive with "has more than 1 folder".
export COPYFILE_DISABLE=1
TAR_FORMAT=ustar

VERSION=$(sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' appinfo/info.xml)
OUT="$PWD/build"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"

# What ships inside the app directory — an explicit allowlist.
#
# This used to be a list of exclusions, which silently shipped the signing key
# once certificate/ appeared in the working copy: .gitignore keeps a file out of
# git, not out of rsync. Anything not named here stays out of the release, so a
# new directory can never leak by default.
APP_CONTENTS=(appinfo lib js img templates COPYING README.md CHANGELOG.md composer.json)

copy_app() {
	local target="$1" item
	for item in "${APP_CONTENTS[@]}"; do
		if [ -e "$item" ]; then
			rsync -a "$item" "$target/"
		else
			echo "  warning: $item is missing from the working copy" >&2
		fi
	done
}

build_variant() {
	local app_id="$1" app_name="$2" namespace="$3"
	local dir="$WORK/$app_id/$app_id"

	mkdir -p "$dir"
	copy_app "$dir"

	if [ "$app_id" != "sharepath" ]; then
		# The app id appears as a literal in the routes the JS calls, in the
		# APP_ID constant and in info.xml. Repository URLs contain
		# "nextcloud-sharing-path" (hyphenated) and are therefore untouched.
		find "$dir/lib" "$dir/js" "$dir/appinfo" "$dir/templates" -type f \
			-exec sed -i '' "s/sharepath/$app_id/g" {} +
		# js/ is included here on purpose: the DOM id enableSharePath is shared
		# between the settings template and settings.js, so both must be renamed
		# in lockstep or the settings toggle silently stops working.
		find "$dir/lib" "$dir/js" "$dir/appinfo" "$dir/templates" -type f \
			-exec sed -i '' "s/SharePath/$namespace/g" {} +
		sed -i '' "s|<name>Share Path</name>|<name>$app_name</name>|" "$dir/appinfo/info.xml"
	fi

	# Drop any extended attributes the working copy picked up before archiving.
	xattr -rc "$dir" 2>/dev/null || true

	tar --format="$TAR_FORMAT" -czf "$OUT/$app_id-$VERSION.tar.gz" -C "$WORK/$app_id" "$app_id"
	echo "  $OUT/$app_id-$VERSION.tar.gz"
}

echo "Building version $VERSION:"
build_variant sharepath "Share Path" SharePath
build_variant sharingpath "Sharing Path" SharingPath
