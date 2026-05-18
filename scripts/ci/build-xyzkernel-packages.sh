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
OUT_ROOT="${OUT_ROOT:-${PWD}/build/ci}"
OUT_DIR="${OUT_DIR:-${OUT_ROOT}/${PACKAGE_FORMAT}}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${PWD}/artifacts}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${PACKAGE_FORMAT}"

if [ -z "${PACKAGE_FORMAT}" ]; then
	echo "PACKAGE_FORMAT must be one of: debian, archlinux, fedora" >&2
	exit 2
fi

case "${PACKAGE_FORMAT}" in
debian|archlinux|fedora) ;;
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
				\( -name '*.deb' -o -name '*.rpm' -o -name '*.pkg.tar.*' \) \
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
		echo "kernelrelease=${kernelrelease}"
		echo "llvm_version=${LLVM_VERSION}"
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
	esac

	copy_new_packages "${marker}"
	write_release_metadata "${kernelrelease}"
}

main() {
	export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"
	export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-xyzkernel}"

	install_deps
	rerun_arch_build_as_user
	setup_llvm
	configure_kernel
	build_package
}

main "$@"
