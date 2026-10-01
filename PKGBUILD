# niri with the screencasting patches needed for portal-based screen sharing
# with Electron clients (QQ, Feishu, ...).
#
# The patch makes niri offer a shm format to portal clients and caps the
# capture frame rate; without it those clients get no picture at all.
#
# To follow a new upstream release:
#   1. rebase the patch onto the new tag
#   2. update _version, _patched and b2sums
#      (run `makepkg -g` to regenerate them from source=(), not `b2sum -g`,
#      which is not a valid option on this system)
#
# Build with:
#   makepkg -si

pkgname=niri-shm-git
# v26.04 was tagged 2026-04-25; the pinned upstream commit is 161 commits
# later, so call this 26.04.161.gc4c01f82 rather than pretending it is the
# release itself.
pkgver=26.04.161.gc4c01f82
pkgrel=2
pkgdesc="Scrollable-tiling Wayland compositor patched so portal screen sharing works with Electron clients"
arch=(aarch64 x86_64)
url="https://github.com/ljm-233/niri-shm"
license=(GPL-3.0-or-later)
depends=(cairo gcc-libs glib2 glibc libinput libpipewire libxkbcommon mesa pango pixman
	 seatd systemd-libs xdg-desktop-portal-gtk)
makedepends=(clang rust)
provides=("niri=$pkgver" "niri")
conflicts=("niri")
options=(!debug !lto)
# Upstream baseline. This is main at 1f03391e, i.e. 161 commits after the
# v26.04 tag: the patch was written against post-26.04 development, where
# pw_utils.rs had already gained the SHM-mapping lifetime rework. Applying it
# to the v26.04 tag fails 6 of 8 hunks, so the exact commit is pinned here
# rather than a tag. Bump this when rebasing the patch onto newer upstream.
_upstream=1f03391ea644c2a43597de7f637269e26d1e1b49
# Short hash of the commit carrying the patch, so `niri --version` reports
# something more useful than "unknown commit".
_patched=9d640bcd
_srcdir=niri
_patchfiles=(
	0001-screencasting-advertise-SHM-and-bound-frame-rate.patch
	0002-screencasting-configurable-frame-rate-and-buffer-pool.patch
)
source=("git+https://github.com/niri-wm/niri.git#commit=$_upstream"
	"${_patchfiles[@]}")
b2sums=('SKIP'
	'36ec8b2265271fd73b595fc4a82138f95eac695673042553936fd8db7183cb8214190f03723368d739929feebc3a384b53882d220bda88ff16ef2605b58bb39c'
	'97817f107370230943bd290d0cd44ae125b45944c50e700799705b61c56e27c564491d86114baa373b5674e49f1a0afa787859e43ac8a06755327a81096ba553')

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
}
