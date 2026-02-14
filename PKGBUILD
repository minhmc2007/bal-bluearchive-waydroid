# Maintainer: minhmc2007 <quangminh21072010@gmail.com>
pkgname=bal-blue-archive-waydroid
pkgver=0.0.2
pkgrel=2
pkgdesc="Automated setup for Blue Archive on Waydroid (GApps, Libhoudini, Android ID)"
arch=('x86_64')
url="" 
license=('GPL')
depends=('waydroid' 'python' 'git' 'curl' 'unzip' 'sqlite' 'sudo' 'python-pip' 'android-tools')
install="${pkgname}.install"
source=("ba-setup.sh")
sha256sums=('SKIP') 

package() {
    # Install the setup script to /usr/bin
    install -Dm755 "ba-setup.sh" "${pkgdir}/usr/bin/ba-setup"
}
