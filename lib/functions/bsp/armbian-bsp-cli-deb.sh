#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function compile_armbian-bsp-cli() {
	: "${artifact_version:?artifact_version is not set}"
	: "${artifact_name:?artifact_name is not set}"
	: "${BOARD:?BOARD is not set}"
	: "${BRANCH:?BRANCH is not set}"

	display_alert "Creating bsp-cli on board '${BOARD}' branch '${BRANCH}'" "${artifact_name} :: ${artifact_version}" "info"

	# "destination" is used a lot in hooks already. keep this name, even if only for compatibility.
	declare cleanup_id="" destination=""
	prepare_temp_dir_in_workdir_and_schedule_cleanup "deb-bsp-cli" cleanup_id destination # namerefs

	mkdir -p "${destination}"/DEBIAN
	cd "${destination}" || exit_with_error "Failed to cd to ${destination}"

	# array of code to be included in postinst (more than base and finish)
	declare -a postinst_functions=()

	declare -a extra_description=()
	[[ "${EXTRA_BSP_NAME}" != "" ]] && extra_description+=("(variant '${EXTRA_BSP_NAME}')")

	# Replaces: base-files is needed to replace /etc/update-motd.d/ files on Xenial
	# Depends: linux-base is needed for "linux-version" command in initrd cleanup script
	# Depends: fping is needed for armbianmonitor to upload armbian-hardware-monitor.log
	cat <<- EOF > "${destination}"/DEBIAN/control
		Package: ${artifact_name}
		Version: ${artifact_version}
		Architecture: $ARCH
		Maintainer: $MAINTAINER <$MAINTAINERMAIL>
		Installed-Size: 1
		Section: kernel
		Priority: optional
		Depends: bash, linux-base, u-boot-tools, initramfs-tools, lsb-release, fping
		Suggests: armbian-config
		Replaces: zram-config, base-files
		Recommends: bsdutils, parted, util-linux, toilet
		Description: Armbian CLI BSP for board '${BOARD}' branch '${BRANCH}' ${extra_description[@]}
	EOF

	# generate minimal DEBIAN/changelog
	cat <<- EOF > "${destination}"/DEBIAN/changelog
		${artifact_name} (${artifact_version}) armbian-repo-name; urgency=low

		  * A fake changelog entry.

		 -- $MAINTAINER <$MAINTAINERMAIL>  $(date -R)
	EOF

	# armhwinfo, firstrun, armbianmonitor, etc. config file; also sourced in postinst
	mkdir -p "${destination}"/etc
	cat <<- EOF > "${destination}"/etc/armbian-release
		# PLEASE DO NOT EDIT THIS FILE
		BOARD=$BOARD
		BOARD_NAME="$BOARD_NAME"
		BOARDFAMILY=${BOARDFAMILY}
		BUILD_REPOSITORY_URL=${BUILD_REPOSITORY_URL}
		BUILD_REPOSITORY_COMMIT=${BUILD_REPOSITORY_COMMIT}
		VERSION=${REVISION}
		LINUXFAMILY=$LINUXFAMILY
		ARCH=$ARCHITECTURE
		IMAGE_TYPE=$IMAGE_TYPE
		BOARD_TYPE=$BOARD_TYPE
		INITRD_ARCH=$INITRD_ARCH
		KERNEL_IMAGE_TYPE=$KERNEL_IMAGE_TYPE
		FORCE_BOOTSCRIPT_UPDATE=$FORCE_BOOTSCRIPT_UPDATE
		VENDOR=$VENDOR
		REVISION=$REVISION
	EOF

	# copy general overlay from packages/bsp-cli
	# in practice: packages/bsp-cli and variations of config/optional/...
	copy_all_packages_files_for "bsp-cli"

	# copy common files from a premade directory structure
	# @TODO this includes systemd config, assumes things about serial console, etc, that need dynamism or just to not exist with modern systemd
	run_host_command_logged rsync -a "${SRC}"/packages/bsp/common/* "${destination}"

	mkdir -p "${destination}"/usr/share/armbian/

	# get bootscript information.
	declare -A bootscript_info=()
	get_bootscript_info

	if [[ "${bootscript_info[has_bootscript]}" == "yes" ]]; then
		# Append some of it to armbian-release
		cat <<- EOF >> "${destination}"/etc/armbian-release
			BOOTSCRIPT_FORCE_UPDATE="${bootscript_info[bootscript_force_update]}"
			BOOTSCRIPT_DST="${bootscript_info[bootscript_dst]}"
		EOF

		# Using bootscript, copy it to /usr/share/armbian
		run_host_command_logged cp -pv "${bootscript_info[bootscript_file_fullpath]}" "${destination}/usr/share/armbian/${bootscript_info[bootscript_dst]}"

		if [[ "${bootscript_info[has_bootenv]}" == "yes" ]]; then
			run_host_command_logged cp -pv "${bootscript_info[bootenv_file_fullpath]}" "${destination}"/usr/share/armbian/armbianEnv.txt
		fi

		# add to postinst, to update bootscript if forced or missing
		postinst_functions+=(board_side_bsp_cli_postinst_update_uboot_bootscript)
	fi

	# add configuration for setting uboot environment from userspace with: fw_setenv fw_printenv
	if [[ -n $UBOOT_FW_ENV ]]; then
		UBOOT_FW_ENV=($(tr ',' ' ' <<< "$UBOOT_FW_ENV"))
		echo "# Device to access      offset           env size" > "${destination}"/etc/fw_env.config
		echo "/dev/mmcblk0	${UBOOT_FW_ENV[0]}	${UBOOT_FW_ENV[1]}" >> "${destination}"/etc/fw_env.config
	fi

	# set up pre install script; use inline functions
	# This is never run in build context; instead, it's source code is dumped inside a file that is packaged.
	# It is done this way so we get shellcheck and formatting instead of a huge heredoc.
	### preinst
	artifact_package_hook_helper_board_side_functions "preinst" board_side_bsp_cli_preinst
	unset board_side_bsp_cli_preinst

	### postrm
	artifact_package_hook_helper_board_side_functions "postrm" board_side_bsp_cli_postrm
	unset board_side_bsp_cli_postrm

	### postinst -- a bit more complex
	artifact_package_hook_helper_board_side_functions "postinst" board_side_bsp_cli_postinst_base "${postinst_functions[@]}" board_side_bsp_cli_postinst_finish
	unset board_side_bsp_cli_postinst_base board_side_bsp_cli_postinst_update_uboot_bootscript board_side_bsp_cli_postinst_finish

	# won't recreate files if they were removed by user
	# TODO: Add proper handling for updated conffiles
	# We are runing this script each time apt runs. If this package is removed, file is removed and error is triggered.
	# Keeping armbian-apt-updates as a configuration, solve the problem
	cat <<- EOF > "${destination}"/DEBIAN/conffiles
		/usr/lib/armbian/armbian-apt-updates
	EOF

	# trigger uInitrd creation after installation, to apply
	# /etc/initramfs/post-update.d/99-uboot
	cat <<- EOF > "${destination}"/DEBIAN/triggers
		activate update-initramfs
	EOF

	# copy distribution support status # @TODO: why? this changes over time and will be out of date
	local releases=($(find ${SRC}/config/distributions -mindepth 1 -maxdepth 1 -type d))
	for i in "${releases[@]}"; do
		echo "$(echo $i | sed 's/.*\///')=$(cat $i/support)" >> "${destination}"/etc/armbian-distribution-status
	done

	# this is required for NFS boot to prevent deconfiguring the network on shutdown
	sed -i 's/#no-auto-down/no-auto-down/g' "${destination}"/etc/network/interfaces.default

	# execute $LINUXFAMILY-specific tweaks
	if [[ $(type -t family_tweaks_bsp) == function ]]; then
		display_alert "Running family_tweaks_bsp" "${LINUXFAMILY} - ${BOARDFAMILY}" "debug"
		family_tweaks_bsp
		display_alert "Done with family_tweaks_bsp" "${LINUXFAMILY} - ${BOARDFAMILY}" "debug"
	fi

	call_extension_method "post_family_tweaks_bsp" <<- 'POST_FAMILY_TWEAKS_BSP'
		*family_tweaks_bsp overrrides what is in the config, so give it a chance to override the family tweaks*
		This should be implemented by the config to tweak the BSP, after the board or family has had the chance to.
	POST_FAMILY_TWEAKS_BSP

	# add some summary to the image # @TODO: another?
	fingerprint_image "${destination}/etc/armbian.txt"

	# fixing permissions (basic), reference: dh_fixperms
	find "${destination}" -print0 2> /dev/null | xargs -0r chown --no-dereference 0:0
	find "${destination}" ! -type l -print0 2> /dev/null | xargs -0r chmod 'go=rX,u+rw,a-s'

	# Build / close the package. This will run shellcheck / show the generated files if debugging
	fakeroot_dpkg_deb_build "${destination}" "${DEB_STORAGE}/"

	done_with_temp_dir "${cleanup_id}" # changes cwd to "${SRC}" and fires the cleanup function early

	display_alert "Done building BSP CLI package" "${destination}" "debug"
}

function get_bootscript_info() {
	bootscript_info[has_bootscript]="no"
	bootscript_info[has_extlinux]="no"
	if [[ -n "${BOOTSCRIPT}" ]] && [[ $SRC_EXTLINUX != yes ]]; then
		bootscript_info[has_bootscript]="yes"

		declare bootscript_source="${BOOTSCRIPT%%:*}"
		declare bootscript_destination="${BOOTSCRIPT##*:}"

		# outer scope
		bootscript_info[bootscript_force_update]="${FORCE_BOOTSCRIPT_UPDATE:-"no"}"
		bootscript_info[bootscript_src]="${bootscript_source}"
		bootscript_info[bootscript_dst]="${bootscript_destination}"
		bootscript_info[bootscript_file_contents]=""

		bootscript_info[bootscript_file_fullpath]="${SRC}/config/bootscripts/${bootscript_source}"
		if [ -f "${USERPATCHES_PATH}/bootscripts/${bootscript_source}" ]; then
			bootscript_info[bootscript_file_fullpath]="${USERPATCHES_PATH}/bootscripts/${bootscript_source}"
		fi
		bootscript_info[bootscript_file_contents]="$(cat "${bootscript_info[bootscript_file_fullpath]}")"

		bootscript_info[bootenv_file_fullpath]=""
		bootscript_info[has_bootenv]="no"
		bootscript_info[bootenv_file_contents]=""
		if [[ -n $BOOTENV_FILE && -f $SRC/config/bootenv/$BOOTENV_FILE ]]; then
			bootscript_info[has_bootenv]="yes"
			bootscript_info[bootenv_file_fullpath]="${SRC}/config/bootenv/${BOOTENV_FILE}"
			bootscript_info[bootenv_file_contents]="$(cat "${SRC}/config/bootenv/${BOOTENV_FILE}")"
		fi
	elif [[ $SRC_EXTLINUX == yes ]]; then
		bootscript_info[has_extlinux]="yes"
		display_alert "Using extlinux, regular bootscripts ignored" "SRC_EXTLINUX=${SRC_EXTLINUX}" "warn"
	fi

	debug_dict bootscript_info
}

function board_side_bsp_cli_postinst_update_uboot_bootscript() {
	if [[ ${BOOTSCRIPT_FORCE_UPDATE} == yes || ! -f /boot/${BOOTSCRIPT_DST} ]]; then

		[ -z ${BOOTSCRIPT_BACKUP_VERSION} ] && BOOTSCRIPT_BACKUP_VERSION="$(date +%s)"
		if [ -f /boot/${BOOTSCRIPT_DST} ]; then
			cp -v /boot/${BOOTSCRIPT_DST} /usr/share/armbian/${BOOTSCRIPT_DST}-${BOOTSCRIPT_BACKUP_VERSION}
			echo "NOTE: You can find previous bootscript versions in /usr/share/armbian !"
		fi

		echo "Recreating boot script"
		cp -v /usr/share/armbian/${BOOTSCRIPT_DST} /boot
		rootdev=$(sed -e 's/^.*root=//' -e 's/ .*\$//' < /proc/cmdline)
		rootfstype=$(sed -e 's/^.*rootfstype=//' -e 's/ .*$//' < /proc/cmdline)

		# recreate armbianEnv.txt if it and extlinux does not exists
		if [ ! -f /boot/armbianEnv.txt ] && [ ! -f /boot/extlinux/extlinux.conf ]; then
			cp -v /usr/share/armbian/armbianEnv.txt /boot
			echo "rootdev="\$rootdev >> /boot/armbianEnv.txt
			echo "rootfstype="\$rootfstype >> /boot/armbianEnv.txt
		fi

		# update boot.ini if it exists? @TODO: why? who uses this?
		[ -f /boot/boot.ini ] && sed -i "s/setenv rootdev.*/setenv rootdev \\"$rootdev\\"/" /boot/boot.ini
		[ -f /boot/boot.ini ] && sed -i "s/setenv rootfstype.*/setenv rootfstype \\"$rootfstype\\"/" /boot/boot.ini

		[ -f /boot/boot.cmd ] && mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr > /dev/null 2>&1
	fi
}

function board_side_bsp_cli_preinst() {
	# tell people to reboot at next login
	[ "$1" = "upgrade" ] && touch /var/run/.reboot_required

	# convert link to file
	if [ -L "/etc/network/interfaces" ]; then
		cp /etc/network/interfaces /etc/network/interfaces.tmp
		rm /etc/network/interfaces
		mv /etc/network/interfaces.tmp /etc/network/interfaces
	fi

	# fixing ramdisk corruption when using lz4 compression method
	sed -i "s/^COMPRESS=.*/COMPRESS=gzip/" /etc/initramfs-tools/initramfs.conf

	# swap
	grep -q vm.swappiness /etc/sysctl.conf
	case $? in
		0)
			sed -i 's/vm\.swappiness.*/vm.swappiness=100/' /etc/sysctl.conf
			;;
		*)
			echo vm.swappiness=100 >> /etc/sysctl.conf
			;;
	esac
	sysctl -p > /dev/null 2>&1
	# replace canonical advertisement
	if [ -d "/var/lib/ubuntu-advantage/messages/" ]; then
		echo -e "\nSupport Armbian! \nLearn more at https://armbian.com/donate" > /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status
		cp /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status /var/lib/ubuntu-advantage/messages/apt-pre-invoke-no-packages-apps.tmpl
		cp /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status /var/lib/ubuntu-advantage/messages/apt-pre-invoke-packages-apps
		cp /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status /var/lib/ubuntu-advantage/messages/apt-pre-invoke-packages-apps.tmpl
	fi
	# disable deprecated services
	[ -f "/etc/profile.d/activate_psd_user.sh" ] && rm /etc/profile.d/activate_psd_user.sh
	[ -f "/etc/profile.d/check_first_login.sh" ] && rm /etc/profile.d/check_first_login.sh
	[ -f "/etc/profile.d/check_first_login_reboot.sh" ] && rm /etc/profile.d/check_first_login_reboot.sh
	[ -f "/etc/profile.d/ssh-title.sh" ] && rm /etc/profile.d/ssh-title.sh
	[ -f "/etc/update-motd.d/10-header" ] && rm /etc/update-motd.d/10-header
	[ -f "/etc/update-motd.d/30-sysinfo" ] && rm /etc/update-motd.d/30-sysinfo
	[ -f "/etc/update-motd.d/35-tips" ] && rm /etc/update-motd.d/35-tips
	[ -f "/etc/update-motd.d/40-updates" ] && rm /etc/update-motd.d/40-updates
	[ -f "/etc/update-motd.d/98-autoreboot-warn" ] && rm /etc/update-motd.d/98-autoreboot-warn
	[ -f "/etc/update-motd.d/99-point-to-faq" ] && rm /etc/update-motd.d/99-point-to-faq
	[ -f "/etc/update-motd.d/80-esm" ] && rm /etc/update-motd.d/80-esm
	[ -f "/etc/update-motd.d/80-livepatch" ] && rm /etc/update-motd.d/80-livepatch
	[ -f "/etc/apt/apt.conf.d/02compress-indexes" ] && rm /etc/apt/apt.conf.d/02compress-indexes
	[ -f "/etc/apt/apt.conf.d/02periodic" ] && rm /etc/apt/apt.conf.d/02periodic
	[ -f "/etc/apt/apt.conf.d/no-languages" ] && rm /etc/apt/apt.conf.d/no-languages
	[ -f "/etc/init.d/armhwinfo" ] && rm /etc/init.d/armhwinfo
	[ -f "/etc/logrotate.d/armhwinfo" ] && rm /etc/logrotate.d/armhwinfo
	[ -f "/etc/init.d/firstrun" ] && rm /etc/init.d/firstrun
	[ -f "/etc/init.d/resize2fs" ] && rm /etc/init.d/resize2fs
	[ -f "/lib/systemd/system/firstrun-config.service" ] && rm /lib/systemd/system/firstrun-config.service
	[ -f "/lib/systemd/system/firstrun.service" ] && rm /lib/systemd/system/firstrun.service
	[ -f "/lib/systemd/system/resize2fs.service" ] && rm /lib/systemd/system/resize2fs.service
	[ -f "/usr/lib/armbian/apt-updates" ] && rm /usr/lib/armbian/apt-updates
	[ -f "/usr/lib/armbian/firstrun-config.sh" ] && rm /usr/lib/armbian/firstrun-config.sh
	# fix for https://bugs.launchpad.net/ubuntu/+source/lightdm-gtk-greeter/+bug/1897491
	[ -d "/var/lib/lightdm" ] && (
		chown -R lightdm:lightdm /var/lib/lightdm
		chmod 0750 /var/lib/lightdm
	)
}

function board_side_bsp_cli_postrm() { # not run here
	if [[ remove == "$1" ]] || [[ abort-install == "$1" ]]; then
		systemctl disable armbian-hardware-monitor.service armbian-hardware-optimize.service > /dev/null 2>&1
		systemctl disable armbian-zram-config.service armbian-ramlog.service > /dev/null 2>&1
	fi
}

function board_side_bsp_cli_postinst_base() {
	# Source the armbian-release information file
	[ -f /etc/armbian-release ] && . /etc/armbian-release

	# Read release value from lsb-release, so deploying a bsp-cli package on top of "X" makes it "Armbian X"
	if [ -f /etc/lsb-release ]; then
		ORIGINAL_DISTRO_RELEASE="$(cat /etc/lsb-release | grep CODENAME | cut -d"=" -f2 | sed 's/.*/\u&/')"
		sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"${VENDOR} $REVISION ${ORIGINAL_DISTRO_RELEASE}\"/" /etc/os-release
		echo -e "${VENDOR} ${REVISION} ${ORIGINAL_DISTRO_RELEASE} \\l \n" > /etc/issue
		echo -e "${VENDOR} ${REVISION} ${ORIGINAL_DISTRO_RELEASE}" > /etc/issue.net
	fi

	# Force ramlog to be enabled if it exists. @TODO: why?
	[ -f /etc/lib/systemd/system/armbian-ramlog.service ] && systemctl --no-reload enable armbian-ramlog.service

	# check if it was disabled in config and disable in new service
	if [ -n "$(grep -w '^ENABLED=false' /etc/default/log2ram 2> /dev/null)" ]; then
		sed -i "s/^ENABLED=.*/ENABLED=false/" /etc/default/armbian-ramlog
	fi

	# fix boot delay "waiting for suspend/resume device"
	if [ -f "/etc/initramfs-tools/initramfs.conf" ]; then
		if ! grep --quiet "RESUME=none" /etc/initramfs-tools/initramfs.conf; then
			echo "RESUME=none" >> /etc/initramfs-tools/initramfs.conf
		fi
	fi
}

function board_side_bsp_cli_postinst_finish() {
	[ ! -f "/etc/network/interfaces" ] && [ -f "/etc/network/interfaces.default" ] && cp /etc/network/interfaces.default /etc/network/interfaces
	ln -sf /var/run/motd /etc/motd
	rm -f /etc/update-motd.d/00-header /etc/update-motd.d/10-help-text

	if [ ! -f "/etc/default/armbian-motd" ]; then
		mv /etc/default/armbian-motd.dpkg-dist /etc/default/armbian-motd
	fi
	if [ ! -f "/etc/default/armbian-ramlog" ] && [ -f /etc/default/armbian-ramlog.dpkg-dist ]; then
		mv /etc/default/armbian-ramlog.dpkg-dist /etc/default/armbian-ramlog
	fi
	if [ ! -f "/etc/default/armbian-zram-config" ] && [ -f /etc/default/armbian-zram-config.dpkg-dist ]; then
		mv /etc/default/armbian-zram-config.dpkg-dist /etc/default/armbian-zram-config
	fi

	if [ -L "/usr/lib/chromium-browser/master_preferences.dpkg-dist" ]; then
		mv /usr/lib/chromium-browser/master_preferences.dpkg-dist /usr/lib/chromium-browser/master_preferences
	fi

	# Reload services
	systemctl --no-reload enable armbian-hardware-monitor.service armbian-hardware-optimize.service armbian-zram-config.service armbian-led-state.service > /dev/null 2>&1
}
