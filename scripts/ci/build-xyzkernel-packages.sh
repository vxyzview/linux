#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

PACKAGE_FORMAT="${PACKAGE_FORMAT:-}"
KERNEL_PACKAGE_NAME="${KERNEL_PACKAGE_NAME:-xyzkernel}"
LLVM_VERSION="${LLVM_VERSION:-22.1.5}"
LLVM_ARCHIVE="${LLVM_ARCHIVE:-LLVM-${LLVM_VERSION}-Linux-X64.tar.xz}"
LLVM_BASE_URL="${LLVM_BASE_URL:-https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}}"
LLVM_URL="${LLVM_URL:-${LLVM_BASE_URL}/${LLVM_ARCHIVE}}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
XYZKERNEL_RELEASE_VERSION="${XYZKERNEL_RELEASE_VERSION:-unknown}"
VOID_PACKAGES_REF="${VOID_PACKAGES_REF:-master}"
OUT_ROOT="${OUT_ROOT:-${PWD}/build/ci}"
OUT_DIR="${OUT_DIR:-${OUT_ROOT}/${PACKAGE_FORMAT}}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${PWD}/artifacts}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${PACKAGE_FORMAT}"

if [ -z "${PACKAGE_FORMAT}" ]; then
	echo "PACKAGE_FORMAT must be one of: debian, archlinux, fedora, voidlinux" >&2
	exit 2
fi

case "${PACKAGE_FORMAT}" in
debian|archlinux|fedora|voidlinux) ;;
*)
	echo "Unsupported PACKAGE_FORMAT=${PACKAGE_FORMAT}" >&2
	exit 2
	;;
esac

install_deps() {
	if [ "${XYZKERNEL_SKIP_DEPS:-0}" = 1 ]; then
		return
	fi

	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get install -y --no-install-recommends \
			bc bison build-essential ca-certificates cpio curl debhelper \
			diffutils dpkg-dev dwarves fakeroot file flex git kmod \
			gcc-x86-64-linux-gnu libdw-dev libelf-dev libncurses6 \
			libssl-dev libxml2 make openssl patch perl python3 rsync tar \
			xz-utils zstd
	elif command -v pacman >/dev/null 2>&1; then
		pacman -Syu --noconfirm --needed \
			base-devel bc bison ca-certificates cpio curl diffutils \
			file flex git kmod libelf libxml2 libxml2-legacy ncurses \
			openssl pahole pacman-contrib patch perl python rsync tar xz \
			zstd
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y \
			bc binutils bison ca-certificates cpio curl diffutils dwarves \
			elfutils-devel elfutils-libelf-devel file findutils flex gcc \
			git kmod libxml2 make ncurses-libs openssl openssl-devel patch \
			perl python3 rpm-build rsync tar xz zstd
	elif command -v xbps-install >/dev/null 2>&1; then
		xbps-install -Syu -y xbps
		xbps-install -y \
			base-devel bc binutils bison ca-certificates cpio curl \
			diffutils elfutils-devel file flex git kmod libxml2-devel \
			ncurses-devel openssl-devel pahole patch perl python3 rsync \
			tar xbps xz zstd
	else
		echo "No supported package manager found for dependency install" >&2
		exit 1
	fi
}

rerun_arch_build_as_user() {
	if [ "${PACKAGE_FORMAT}" != archlinux ] ||
	   [ "$(id -u)" -ne 0 ] ||
	   [ "${XYZKERNEL_BUILDER_USER:-0}" = 1 ]; then
		return
	fi

	local uid gid group
	uid="${HOST_UID:-1000}"
	gid="${HOST_GID:-1000}"
	group=xyzkernel

	if ! getent group "${gid}" >/dev/null 2>&1; then
		groupadd -g "${gid}" "${group}"
	else
		group="$(getent group "${gid}" | cut -d: -f1)"
	fi

	if ! id -u builder >/dev/null 2>&1; then
		useradd -m -u "${uid}" -g "${gid}" -s /bin/bash builder
	fi

	mkdir -p "${OUT_ROOT}" "${ARTIFACT_ROOT}"
	chown -R "${uid}:${gid}" "${PWD}" "${OUT_ROOT}" "${ARTIFACT_ROOT}"

	exec runuser -u builder -- env \
		ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
		GITHUB_RUN_NUMBER="${GITHUB_RUN_NUMBER:-}" \
		GITHUB_SHA="${GITHUB_SHA:-}" \
		HOME="/home/builder" \
		KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}" \
		KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-xyzkernel}" \
		KERNEL_PACKAGE_NAME="${KERNEL_PACKAGE_NAME}" \
		LLVM_ARCHIVE="${LLVM_ARCHIVE}" \
		LLVM_BASE_URL="${LLVM_BASE_URL}" \
		LLVM_URL="${LLVM_URL}" \
		LLVM_VERSION="${LLVM_VERSION}" \
		MAKE_JOBS="${MAKE_JOBS}" \
		OUT_DIR="${OUT_DIR}" \
		OUT_ROOT="${OUT_ROOT}" \
		PACKAGE_FORMAT="${PACKAGE_FORMAT}" \
		XYZKERNEL_RELEASE_VERSION="${XYZKERNEL_RELEASE_VERSION}" \
		XYZKERNEL_BUILDER_USER=1 \
		XYZKERNEL_SKIP_DEPS=1 \
		bash "$0"
}

setup_llvm() {
	local llvm_dir llvm_tar
	llvm_dir="${OUT_ROOT}/llvm-${LLVM_VERSION}"
	llvm_tar="${OUT_ROOT}/${LLVM_ARCHIVE}"

	if [ ! -x "${llvm_dir}/bin/clang" ]; then
		mkdir -p "${OUT_ROOT}"
		curl -L --fail --retry 3 -o "${llvm_tar}" "${LLVM_URL}"
		rm -rf "${llvm_dir}"
		mkdir -p "${llvm_dir}"
		tar -xJf "${llvm_tar}" -C "${llvm_dir}" --strip-components=1
	fi

	export PATH="${llvm_dir}/bin:${PATH}"
	export LLVM=1
	export LLVM_IAS=1
	clang --version
	ld.lld --version
}

make_kernel() {
	make O="${OUT_DIR}" LLVM=1 LLVM_IAS=1 "$@"
}

apply_void_linux_patches() {
	local patch_dir patch_file patch_name patch_url
	local api_url="https://api.github.com/repos/void-linux/void-packages/contents/srcpkgs/linux7.0/patches?ref=${VOID_PACKAGES_REF}"
	local -a patch_urls

	if [ "${PACKAGE_FORMAT}" != voidlinux ]; then
		return
	fi

	patch_dir="${OUT_ROOT}/voidlinux-patches"
	rm -rf "${patch_dir}"
	mkdir -p "${patch_dir}" "${OUT_DIR}"

	mapfile -t patch_urls < <(
		curl -fsSL "${api_url}" |
			sed -n 's/^[[:space:]]*"download_url": "\(.*\.patch\)",$/\1/p' |
			LC_ALL=C sort
	)

	if [ "${#patch_urls[@]}" -eq 0 ]; then
		echo "No Void Linux kernel patches found at ${api_url}" >&2
		exit 1
	fi

	for patch_url in "${patch_urls[@]}"; do
		patch_name="${patch_url##*/}"
		patch_file="${patch_dir}/${patch_name}"
		curl -fsSL -o "${patch_file}" "${patch_url}"
		echo "Applying Void Linux patch ${patch_name}"
		if git apply --check "${patch_file}"; then
			git apply "${patch_file}"
		elif git apply --reverse --check "${patch_file}"; then
			echo "Void Linux patch ${patch_name} is already applied"
		elif void_patch_already_applied "${patch_name}"; then
			echo "Void Linux patch ${patch_name} is already present in this tree"
		else
			echo "Void Linux patch ${patch_name} does not apply cleanly" >&2
			git apply --stat "${patch_file}" >&2 || true
			exit 1
		fi
	done

	printf '%s\n' "${patch_urls[@]##*/}" > "${OUT_DIR}/voidlinux-patches-applied.txt"
}

void_patch_already_applied() {
	case "$1" in
	fix-ccache.patch)
		grep -Fqx '	// conf_write_heading(file, comment_style);' scripts/kconfig/confdata.c
		;;
	fix-musl-btf-ids.patch)
		grep -Fqx '#include <linux/types.h> /* for u32 */' tools/include/linux/btf_ids.h
		;;
	fixdep-largefile.patch)
		grep -Fqx '#define _FILE_OFFSET_BITS 64' tools/build/fixdep.c
		;;
	*)
		return 1
		;;
	esac
}

require_config() {
	local key value file
	key="$1"
	value="$2"
	file="${OUT_DIR}/.config"

	if ! grep -qx "${key}=${value}" "${file}"; then
		echo "Required ${key}=${value} was not selected in ${file}" >&2
		grep -n "${key}\\|LTO_CLANG\\|CC_OPTIMIZE\\|CC_IS_CLANG\\|LD_IS_LLD\\|AS_IS_LLVM" "${file}" >&2 || true
		exit 1
	fi
}

configure_kernel() {
	mkdir -p "${OUT_DIR}"
	git config --global --add safe.directory "${PWD}" || true
	make_kernel xyz_defconfig
	make_kernel olddefconfig

	require_config CONFIG_CC_IS_CLANG y
	require_config CONFIG_LD_IS_LLD y
	require_config CONFIG_AS_IS_LLVM y
	require_config CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3 y
	require_config CONFIG_LTO_CLANG_FULL y
}

copy_new_packages() {
	local marker release_dir package_count roots root prune_out_root
	marker="$1"
	release_dir="${ARTIFACT_DIR}/release"
	package_count=0
	roots=("${OUT_ROOT}" "${PWD}")

	rm -rf "${ARTIFACT_DIR}"
	mkdir -p "${release_dir}"

	for root in "${roots[@]}"; do
		[ -d "${root}" ] || continue
		prune_out_root=()
		if [ "${root}" = "${PWD}" ] && [ "${OUT_ROOT}" != "${PWD}" ]; then
			prune_out_root=(-path "${OUT_ROOT}" -prune -o)
		fi

		while IFS= read -r -d '' pkg; do
			cp -v "${pkg}" "${release_dir}/"
			package_count=$((package_count + 1))
		done < <(
			find "${root}" -path "${PWD}/.git" -prune -o \
				-path "${ARTIFACT_ROOT}" -prune -o \
				"${prune_out_root[@]}" \
				-type f -newer "${marker}" \
				\( -name '*.deb' -o -name '*.rpm' -o -name '*.pkg.tar.*' -o -name '*.xbps' \) \
				-print0
		)
	done

	if [ "${package_count}" -eq 0 ]; then
		echo "No package artifacts were produced for ${PACKAGE_FORMAT}" >&2
		exit 1
	fi
}

write_release_metadata() {
	local kernelrelease release_dir build_info checksum_manifest
	kernelrelease="$1"
	release_dir="${ARTIFACT_DIR}/release"
	build_info="${release_dir}/${KERNEL_PACKAGE_NAME}-${PACKAGE_FORMAT}-${kernelrelease}-build-info.txt"
	checksum_manifest="${release_dir}/${KERNEL_PACKAGE_NAME}-${PACKAGE_FORMAT}-${kernelrelease}-SHA256SUMS.txt"

	{
		echo "package_name=${KERNEL_PACKAGE_NAME}"
		echo "package_format=${PACKAGE_FORMAT}"
		echo "release_version=${XYZKERNEL_RELEASE_VERSION}"
		echo "kernelrelease=${kernelrelease}"
		echo "llvm_version=${LLVM_VERSION}"
		if [ "${PACKAGE_FORMAT}" = voidlinux ]; then
			echo "void_packages_ref=${VOID_PACKAGES_REF}"
			if [ -f "${OUT_DIR}/voidlinux-patches-applied.txt" ]; then
				echo "void_patches=$(paste -sd, "${OUT_DIR}/voidlinux-patches-applied.txt")"
			fi
		fi
		echo "make_jobs=${MAKE_JOBS}"
		echo "source_sha=${GITHUB_SHA:-unknown}"
		echo
		clang --version
		echo
		make_kernel -s kernelversion
		echo
		grep -E '^(CONFIG_CC_IS_CLANG|CONFIG_LD_IS_LLD|CONFIG_AS_IS_LLVM|CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3|CONFIG_LTO_CLANG_FULL)=' "${OUT_DIR}/.config"
	} > "${build_info}"

	(
		cd "${release_dir}"
		rm -f ./*.sha256 "${checksum_manifest##*/}"

		mapfile -t checksum_files < <(
			find . -maxdepth 1 -type f \
				! -name '*.sha256' \
				! -name '*-SHA256SUMS.txt' \
				-printf '%P\n' | LC_ALL=C sort
		)

		sha256sum "${checksum_files[@]}" > "${checksum_manifest##*/}"
		for file in "${checksum_files[@]}"; do
			sha256sum "${file}" > "${file}.sha256"
		done
	)
}

write_void_kernel_hook_scripts() {
	local root kernelrelease
	root="$1"
	kernelrelease="$2"

	cat > "${root}/INSTALL" <<'EOF'
#!/bin/sh
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"

TRIGGERSDIR="./usr/libexec/xbps-triggers"
ACTION="$1"
PKGNAME="$2"
VERSION="$3"
UPDATE="$4"
CONF_FILE="$5"

export kernel_hooks_version="@KERNELRELEASE@"

run_kernel_hooks() {
	[ -x "${TRIGGERSDIR}/kernel-hooks" ] || exit 0
	"${TRIGGERSDIR}/kernel-hooks" run "$1" "${PKGNAME}" "${VERSION}" "${UPDATE}" "${CONF_FILE}"
}

case "${ACTION}" in
pre)
	run_kernel_hooks pre-install
	;;
post)
	run_kernel_hooks post-install
	;;
esac

exit 0
EOF

	cat > "${root}/REMOVE" <<'EOF'
#!/bin/sh
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"

TRIGGERSDIR="./usr/libexec/xbps-triggers"
ACTION="$1"
PKGNAME="$2"
VERSION="$3"
UPDATE="$4"
CONF_FILE="$5"

export kernel_hooks_version="@KERNELRELEASE@"

run_kernel_hooks() {
	[ -x "${TRIGGERSDIR}/kernel-hooks" ] || exit 0
	"${TRIGGERSDIR}/kernel-hooks" run "$1" "${PKGNAME}" "${VERSION}" "${UPDATE}" "${CONF_FILE}"
}

case "${ACTION}" in
pre)
	run_kernel_hooks pre-remove
	;;
post)
	run_kernel_hooks post-remove
	;;
esac

exit 0
EOF

	sed -i "s/@KERNELRELEASE@/${kernelrelease}/g" "${root}/INSTALL" "${root}/REMOVE"
	chmod 755 "${root}/INSTALL" "${root}/REMOVE"
}

copy_kernel_header_tree() {
	local hdrdest kernelrelease source_arch
	hdrdest="$1"
	kernelrelease="$2"
	source_arch="${3:-x86}"

	mkdir -p "${hdrdest}"
	install -Dm644 Makefile "${hdrdest}/Makefile"
	install -Dm644 Kbuild "${hdrdest}/Kbuild"
	install -Dm644 "${OUT_DIR}/.config" "${hdrdest}/.config"
	[ -f "${OUT_DIR}/Module.symvers" ] && install -Dm644 "${OUT_DIR}/Module.symvers" "${hdrdest}/Module.symvers"
	[ -f "${OUT_DIR}/System.map" ] && install -Dm644 "${OUT_DIR}/System.map" "${hdrdest}/System.map"

	cp -a include "${hdrdest}/include"
	mkdir -p "${hdrdest}/arch/${source_arch}"
	cp -a "arch/${source_arch}/include" "${hdrdest}/arch/${source_arch}/include"
	cp -a scripts "${hdrdest}/scripts"

	if [ -d "${OUT_DIR}/include/generated" ]; then
		mkdir -p "${hdrdest}/include"
		cp -a "${OUT_DIR}/include/generated" "${hdrdest}/include/generated"
	fi
	if [ -d "${OUT_DIR}/arch/${source_arch}/include/generated" ]; then
		mkdir -p "${hdrdest}/arch/${source_arch}/include"
		cp -a "${OUT_DIR}/arch/${source_arch}/include/generated" "${hdrdest}/arch/${source_arch}/include/generated"
	fi
	if [ -d "${OUT_DIR}/scripts" ]; then
		cp -a "${OUT_DIR}/scripts/." "${hdrdest}/scripts/"
	fi
	if [ -d tools/include ]; then
		mkdir -p "${hdrdest}/tools"
		cp -a tools/include "${hdrdest}/tools/include"
	fi
	if [ -x "${OUT_DIR}/tools/objtool/objtool" ]; then
		mkdir -p "${hdrdest}/tools/objtool"
		cp -a "${OUT_DIR}/tools/objtool/objtool" "${hdrdest}/tools/objtool/objtool"
	fi

	find "${hdrdest}" -name '.gitignore' -delete
	echo "${kernelrelease}" > "${hdrdest}/kernel.release"
}

build_voidlinux_xbps() {
	local kernelrelease kernelversion revision xbps_pkgver xbps_arch
	local pkgwork pkgout pkgroot hdrroot hdrdest module_dir mutable_files

	kernelrelease="$1"
	kernelversion="$(make_kernel -s kernelversion)"
	revision="${GITHUB_RUN_NUMBER:-1}"
	xbps_pkgver="${kernelversion}_${revision}"
	xbps_arch="$(xbps-uhelper arch 2>/dev/null || uname -m)"
	pkgwork="${OUT_DIR}/voidlinux-xbps"
	pkgout="${pkgwork}/out"
	pkgroot="${pkgwork}/${KERNEL_PACKAGE_NAME}"
	hdrroot="${pkgwork}/${KERNEL_PACKAGE_NAME}-headers"
	hdrdest="${hdrroot}/usr/src/kernel-headers-${kernelrelease}"
	module_dir="${pkgroot}/usr/lib/modules/${kernelrelease}"

	rm -rf "${pkgwork}"
	mkdir -p "${pkgout}" "${pkgroot}/boot" "${hdrroot}"

	make_kernel -j"${MAKE_JOBS}" bzImage modules
	make_kernel -j"${MAKE_JOBS}" INSTALL_MOD_PATH="${pkgroot}/usr" DEPMOD=true modules_install

	rm -rf "${pkgroot}/usr/lib/firmware"
	install -Dm644 "${OUT_DIR}/.config" "${pkgroot}/boot/config-${kernelrelease}"
	install -Dm644 "${OUT_DIR}/System.map" "${pkgroot}/boot/System.map-${kernelrelease}"
	install -Dm644 "${OUT_DIR}/arch/x86/boot/bzImage" "${pkgroot}/boot/vmlinuz-${kernelrelease}"

	rm -f "${module_dir}/build" "${module_dir}/source"
	ln -sf "../../../src/kernel-headers-${kernelrelease}" "${module_dir}/build"
	ln -sf "../../../src/kernel-headers-${kernelrelease}" "${module_dir}/source"
	depmod -b "${pkgroot}/usr" -F "${OUT_DIR}/System.map" "${kernelrelease}"

	write_void_kernel_hook_scripts "${pkgroot}" "${kernelrelease}"
	copy_kernel_header_tree "${hdrdest}" "${kernelrelease}" x86

	mutable_files="
/usr/lib/modules/${kernelrelease}/modules.alias
/usr/lib/modules/${kernelrelease}/modules.alias.bin
/usr/lib/modules/${kernelrelease}/modules.builtin.alias.bin
/usr/lib/modules/${kernelrelease}/modules.builtin.bin
/usr/lib/modules/${kernelrelease}/modules.dep
/usr/lib/modules/${kernelrelease}/modules.dep.bin
/usr/lib/modules/${kernelrelease}/modules.devname
/usr/lib/modules/${kernelrelease}/modules.softdep
/usr/lib/modules/${kernelrelease}/modules.symbols
/usr/lib/modules/${kernelrelease}/modules.symbols.bin"

	(
		cd "${pkgout}"
		xbps-create \
			--architecture "${xbps_arch}" \
			--homepage "https://github.com/${GITHUB_REPOSITORY:-xyzkernel/xyzkernel}" \
			--license "GPL-2.0-only" \
			--maintainer "xyzkernel builder <xyzkernel@example.invalid>" \
			--mutable-files "$(echo "${mutable_files}")" \
			--preserve \
			--desc "xyzkernel Linux kernel and modules (${kernelversion} series)" \
			--pkgver "${KERNEL_PACKAGE_NAME}-${xbps_pkgver}" \
			"${pkgroot}"

		xbps-create \
			--architecture "${xbps_arch}" \
			--homepage "https://github.com/${GITHUB_REPOSITORY:-xyzkernel/xyzkernel}" \
			--license "GPL-2.0-only" \
			--maintainer "xyzkernel builder <xyzkernel@example.invalid>" \
			--preserve \
			--desc "xyzkernel source headers for external modules" \
			--pkgver "${KERNEL_PACKAGE_NAME}-headers-${xbps_pkgver}" \
			"${hdrroot}"
	)
}

build_package() {
	local marker kernelrelease
	marker="${OUT_ROOT}/.${PACKAGE_FORMAT}.package-start"
	: > "${marker}"

	case "${PACKAGE_FORMAT}" in
	debian)
		export DEBFULLNAME="${DEBFULLNAME:-xyzkernel builder}"
		export DEBEMAIL="${DEBEMAIL:-xyzkernel@example.invalid}"
		export KDEB_SOURCENAME="${KDEB_SOURCENAME:-${KERNEL_PACKAGE_NAME}}"
		export KDEB_IMAGE_PACKAGE_NAME="${KDEB_IMAGE_PACKAGE_NAME:-${KERNEL_PACKAGE_NAME}}"
		export KDEB_HEADERS_PACKAGE_NAME="${KDEB_HEADERS_PACKAGE_NAME:-${KERNEL_PACKAGE_NAME}-headers}"
		export KDEB_CHANGELOG_DIST="${KDEB_CHANGELOG_DIST:-unstable}"
		export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-parallel=${MAKE_JOBS}}"
		export DEB_BUILD_PROFILES="${DEB_BUILD_PROFILES:-pkg.${KDEB_SOURCENAME}.nokerneldbg}"
		kernelrelease="$(make_kernel -s kernelrelease)"
		export KDEB_PKGVERSION="${KDEB_PKGVERSION:-${kernelrelease//-/.}-${GITHUB_RUN_NUMBER:-1}}"
		make_kernel -j"${MAKE_JOBS}" bindeb-pkg
		;;
	archlinux)
		export PACMAN_PKGBASE="${PACMAN_PKGBASE:-${KERNEL_PACKAGE_NAME}}"
		export PACMAN_EXTRAPACKAGES="${PACMAN_EXTRAPACKAGES:-headers}"
		export MAKEPKGOPTS="${MAKEPKGOPTS:---noconfirm --syncdeps --needed --skippgpcheck --nocheck}"
		kernelrelease="$(make_kernel -s kernelrelease)"
		make_kernel -j"${MAKE_JOBS}" pacman-pkg
		;;
	fedora)
		export KRPM_PACKAGE_NAME="${KRPM_PACKAGE_NAME:-${KERNEL_PACKAGE_NAME}}"
		export RPMOPTS="${RPMOPTS:---without debuginfo}"
		kernelrelease="$(make_kernel -s kernelrelease)"
		make_kernel -j"${MAKE_JOBS}" binrpm-pkg
		;;
	voidlinux)
		kernelrelease="$(make_kernel -s kernelrelease)"
		build_voidlinux_xbps "${kernelrelease}"
		;;
	esac

	copy_new_packages "${marker}"
	write_release_metadata "${kernelrelease}"
}

main() {
	export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"
	export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-xyzkernel}"

	install_deps
	rerun_arch_build_as_user
	apply_void_linux_patches
	setup_llvm
	configure_kernel
	build_package
}

main "$@"
