# niri with the screencasting patches that make portal-based screen capture
# work at all on it.
#
# Without these patches niri offers no shm format and does not advertise
# AvailableSourceTypes / AvailableCursorModes on the mutter screen cast
# interface, so xdg-desktop-portal-gnome reports zero capability and refuses
# every SelectSources call. Electron clients (QQ, Feishu, ...) get no picture
# whatsoever, not even a full-screen one.
#
# The patches also put a ceiling on the capture frame rate. Advertising
# VideoFramerate 0/1 means "unlimited", which makes PipeWire push frames at the
# output refresh rate; a software encoder cannot drain them fast enough and the
# leftover raw frames pile up in shm.
#
# To follow a new upstream release:
#   1. rebase the patch onto the new tag
#   2. update _version, _patched and b2sums
#      (run `makepkg -g` to regenerate them from source=(), not `b2sum -g`,
#      which is not a valid option on this system)
#
# Build with:
#   makepkg -si

pkgname=niri-portal-cast
# pkgver is the date this package was built plus a same-day counter, not the
# upstream version. The upstream baseline is pinned separately in _upstream
# and _patched below; a date-based version is what keeps pacman's ordering
# correct, because a semantic version like 26.0.7 would sort below the
# previous 26.04.165.g61dc3de4 and every install would need --allow-downgrade.
pkgver=2026.10.3
pkgrel=7
pkgdesc="Scrollable-tiling Wayland compositor patched so portal screen capture works with Electron clients"
arch=(x86_64)
url="https://github.com/ljm-233/niri-portal-cast"
license=(GPL-3.0-or-later)
depends=(cairo gcc-libs glib2 glibc libinput libpipewire libxkbcommon mesa pango pixman
	 seatd systemd-libs xdg-desktop-portal-gtk)
makedepends=(clang rust)
# The build is pinned to a commit past the v26.04 tag, so it cannot honestly
# claim niri=<the pinned commit> -- that version does not exist upstream, and
# a dependency on it could never be satisfied. Claim the release it descends
# from instead.
provides=("niri=26.04" "niri")
conflicts=("niri")
options=(!debug !lto)
# Upstream baseline. This is main at ed22699d, i.e. 165 commits after the
# v26.04 tag: the patch was written against post-26.04 development, where
# pw_utils.rs had already gained the SHM-mapping lifetime rework. Applying it
# to the v26.04 tag fails 6 of 8 hunks, so the exact commit is pinned here
# rather than a tag. Bump this when rebasing the patch onto newer upstream.
_upstream=ed22699d99462f61ab171472d3ea67e844ea580d
# Short hash of the commit carrying the patch, so `niri --version` reports
# something more useful than "unknown commit".
_patched=61dc3de4
_srcdir=niri
_patchfiles=(
	0001-screencasting-advertise-SHM-and-bound-frame-rate.patch
	0002-screencasting-configurable-frame-rate-and-buffer-pool.patch
	0003-screencasting-drop-nonexistent-shm-buffer-bound.patch
)
source=("git+https://github.com/niri-wm/niri.git#commit=$_upstream"
	"${_patchfiles[@]}")
b2sums=('SKIP'
	'11c822ffd4dc3053e7ca638693e036d18751784df5a14a3955229237bb2f2a8ce9124f035cd8c1d7c908e5d26d189a289ec3fea7e2054b2a1b6a0b265ef3d6fd'
	'ed92df5545848ae0e11e03e31f5c3fb46d1b1641975c14464630440cbc8db23d289b87739277d4718cbfbd2f21c91efb673010aaeedda1fae87540a2dc6933ae'
	'2ea209aec395a9d1f62e0ee9cd48ac7330f73eaa752f249cf734515c27e8be20958e31feb6849be0e6ec6325238f52e5c5a3b5f3dd3d0d86fd1ec64676a51f94')

prepare() {
	cd "$_srcdir"
	local patchfile
	for patchfile in "${_patchfiles[@]}"; do
		patch -Np1 -i "$srcdir/$patchfile"
	done
}

build() {
	cd "$_srcdir"
	# niri reads these at compile time (src/utils/mod.rs::version). Setting
	# the commit hash here keeps `niri --version` honest without patching the
	# source file, which would break again if upstream moves that code.
	export NIRI_BUILD_COMMIT="$_patched"
	cargo build --frozen --release
}

check() {
	cd "$_srcdir"
	cargo test --frozen --release
}

package() {
	cd "$_srcdir"
	install -Dm755 target/release/niri -t "$pkgdir"/usr/bin/
	install -Dm755 resources/niri-session -t "$pkgdir"/usr/bin/
	install -Dm644 resources/niri.service -t "$pkgdir"/usr/lib/systemd/user/
	install -Dm644 resources/niri-shutdown.target -t "$pkgdir"/usr/lib/systemd/user/
	install -Dm644 resources/default-config.kdl -t "$pkgdir"/usr/share/doc/$pkgname/
	install -Dm644 resources/niri.desktop -t "$pkgdir"/usr/share/wayland-sessions/
	install -Dm644 resources/niri-portals.conf -t "$pkgdir"/usr/share/xdg-desktop-portal/
	# Diagnostics for "I click share and get nothing". Reads state only, never
	# restarts anything, so it is safe to run mid-call.
	# $srcdir is the download cache and does not contain the script, so it is
	# taken from the build directory (startdir) instead.
	install -Dm755 "$startdir/niri-portal-doctor.sh" "$pkgdir"/usr/bin/niri-portal-doctor
}
