#!/bin/bash

#set -e

vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/geco-pve/coreos
SNIPPETS_FILES_PATH=/var/lib/vz/snippets
YQ="/usr/local/bin/yq read --exitStatus --printMode v --stripComments --"
VMCONF="/etc/pve/qemu-server/${vmid}.conf"

# ==================================================================================================================================================================
# functions()
#
setup_fcoreosct()
{
        local CT_VER=0.7.0
        local ARCH=x86_64
        local OS=unknown-linux-gnu # Linux
        local DOWNLOAD_URL=https://github.com/coreos/fcct/releases/download

        [[ -x /usr/local/bin/fcos-ct ]]&& [[ "x$(/usr/local/bin/fcos-ct --version | awk '{print $NF}')" == "x${CT_VER}" ]]&& return 0
        echo "Setup Fedora CoreOS config transpiler..."
        rm -f /usr/local/bin/fcos-ct
        wget --quiet --show-progress ${DOWNLOAD_URL}/v${CT_VER}/fcct-${ARCH}-${OS} -O /usr/local/bin/fcos-ct
        chmod 755 /usr/local/bin/fcos-ct
}
setup_fcoreosct

setup_yq()
{
        local VER=3.4.1

        [[ -x /usr/bin/wget ]]&& download_command="wget --quiet --show-progress --output-document"  || download_command="curl --location --output"
        [[ -x /usr/local/bin/yq ]]&& [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]]&& return 0
        echo "Setup yaml parser tools yq..."
        rm -f /usr/local/bin/yq
        ${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64
        chmod 755 /usr/local/bin/yq
}
setup_yq

mask2cdr()
{
        # Assumes there's no "255." after a non-255 byte in the mask
        local x=${1##*255.}
        set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
        x=${1%%$3*}
        echo $(( $2 + (${#x}/4) ))
}

# Parse network overrides from the VM notes (description field) and print them
# as a yaml "network:" list for the vendor-data snippet.
# Lines starting with # or ; are comments, everything else outside the
# recognized syntax is ignored:
#   [net0]
#   mac=bc:24:11:aa:bb:cc
#   ipv4=192.168.1.10/24     (or: dhcp)
#   ipv4_gateway=192.168.1.1
#   ipv6=slaac               (slaac|dhcp|disabled)
#   ipv6_privacy=on          (on|off)
generate_notes_network()
{
    local desc section line key value
    desc="$(pvesh get /nodes/$(hostname)/qemu/${vmid}/config --output-format json 2>/dev/null | ${YQ} - 'description' 2>/dev/null)" || return 0
    [[ -n "${desc}" ]] || return 0

    section=""
    while IFS= read -r line; do
        line="$(echo "${line}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ "${line}" =~ ^[#\;] ]] && continue # comment, e.g. the template example
        if [[ "${line}" =~ ^\[net([0-9]+)\]$ ]]; then
            section="net${BASH_REMATCH[1]}"
            echo "   - name: ${section}"
            continue
        fi
        [[ "${line}" =~ ^\[.*\]$ ]] && { section=""; continue; }
        [[ -n "${section}" ]] || continue
        [[ "${line}" == *=* ]] || continue
        key="$(echo "${line%%=*}" | sed -e 's/[[:space:]]*$//' | tr 'A-Z-' 'a-z_')"
        value="$(echo "${line#*=}" | sed -e 's/^[[:space:]]*//')"
        case "${key}" in
            mac|mac_address) echo "     mac: \"${value}\"" ;;
            ipv4|ipv4_gateway|ipv6|ipv6_privacy) echo "     ${key}: \"${value}\"" ;;
        esac
    done <<< "${desc}"
}

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]
then
    NEEDS_RESTART=false

    # ==================================================================================================================================================================
    # Vendor-data snippet generieren (network overrides aus dem Notes Feld)
    # Virtiofs mounts werden seit geco-virtiofs im Gast selbst über /sys/fs/virtiofs erkannt
    # ==================================================================================================================================================================
    echo "Fedora CoreOS: Generate vendor-data snippet... "
    if [[ -f "${VMCONF}" ]]; then

        old_hash=""
        [[ -f "${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml" ]] && \
            pvesh get /nodes/$(hostname)/qemu/${vmid}/config 2>/dev/null | grep -q cicustom && \
            old_hash="$(md5sum "${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml" | awk '{print $1}')"

        echo "# Managed by hook-fcos.sh, do not edit." > "${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml"

        # Network overrides from the VM notes field (see generate_notes_network).
        # They end up on the cloudinit iso as vendor-data and are applied inside
        # the VM by /usr/local/bin/geco-network on every boot.
        echo "Fedora CoreOS: Generate network overrides from VM notes... "
        network_overrides="$(generate_notes_network)"
        [[ -n "${network_overrides}" ]] && {
            echo "network:" >> "${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml"
            echo "${network_overrides}" >> "${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml"
        }

        new_hash="$(md5sum "${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml" | awk '{print $1}')"
        cicustom_path="vendor=local:snippets/${vmid}-vendor-data.yaml"

        if [[ "x${old_hash}" != "x${new_hash}" ]]; then
            echo "Fedora CoreOS: vendor-data changed, applying..."
            rm -f /var/lock/qemu-server/lock-${vmid}.conf
            pvesh set /nodes/$(hostname)/qemu/${vmid}/config \
                --cicustom "${cicustom_path}" 2>/dev/null || { echo "[failed]"; exit 1; }
            touch /var/lock/qemu-server/lock-${vmid}.conf
            NEEDS_RESTART=true
        fi
    fi
    echo "[done]"

    # ==================================================================================================================================================================
    # Cloudinit / Ignition config generieren
    # ==================================================================================================================================================================
	instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} - 'instance-id')"

	# same cloudinit config ?
	[[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]]&& {
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
	}
	# template newer than the cached ignition ? (also catches stale caches of deleted/recreated vmids)
	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]] && [[ -e "${COREOS_TMPLT}" ]] && [[ "${COREOS_TMPLT}" -nt ${COREOS_FILES_PATH}/${vmid}.ign ]]&& {
		echo "Fedora CoreOS: ignition template changed, regenerating..."
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign
	}
	# Ignition noch nicht vorhanden -> neu generieren
    if [[ ! -e ${COREOS_FILES_PATH}/${vmid}.ign ]]; then
        mkdir -p ${COREOS_FILES_PATH} || exit 1
    	# check config
    	cipasswd="$(qm cloudinit dump ${vmid} user | ${YQ} - 'password' 2> /dev/null)" || true # can be empty
    	[[ "x${cipasswd}" != "x" ]]&& VALIDCONFIG=true
    	${VALIDCONFIG:-false} || [[ "x$(qm cloudinit dump ${vmid} user | ${YQ} - 'ssh_authorized_keys[*]')" == "x" ]]|| VALIDCONFIG=true
    	${VALIDCONFIG:-false} || {
    		echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
    		exit 1
    	}

    	echo -n "Fedora CoreOS: Generate yaml users block... "
    	echo -e "# This file is managed by Geco-iT hook-script. Do not edit.\n" > ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo -e "variant: fcos\nversion: 1.1.0" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo -e "# user\npasswd:\n  users:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
    	echo "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "      gecos: \"Geco-iT CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	qm cloudinit dump ${vmid} user | ${YQ} - 'ssh_authorized_keys[*]' | sed -e 's/^/        - "/' -e 's/$/"/' >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "[done]"

    	echo -n "Fedora CoreOS: Generate yaml hostname block... "
    	hostname="$(qm cloudinit dump ${vmid} user | ${YQ} - 'hostname' 2> /dev/null)"
    	echo -e "# network\nstorage:\n  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "    - path: /etc/hostname" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "      mode: 0644" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo -e "          ${hostname,,}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    	echo "[done]"

    	echo -n "Fedora CoreOS: Generate yaml network block... "
    	# Merge cloudinit network config with the notes overrides (vendor-data) so the
    	# very first boot already has the final network configuration. The rendered
    	# content must stay identical to what geco-network generates inside the VM,
    	# otherwise the first boot changes the network mid-boot again.
    	vendor_file="${SNIPPETS_FILES_PATH}/${vmid}-vendor-data.yaml"
    	netcards="$(qm cloudinit dump ${vmid} network | ${YQ} - 'config[*].name' 2> /dev/null | wc -l)"
        nameservers="$(qm cloudinit dump ${vmid} network | ${YQ} - "config[${netcards}].address[*]" | paste -s -d ";" -)"
        searchdomain="$(qm cloudinit dump ${vmid} network | ${YQ} - "config[${netcards}].search[*]" | paste -s -d ";" -)"

        declare -A ifmac ifipv4 ifipv4_gw ifipv6 ifipv6_addr ifipv6_gw ifipv6_privacy
        IFACES=()
        add_iface() {
            local name
            for name in "${IFACES[@]}"; do [[ "${name}" == "${1}" ]]&& return 0; done
            IFACES+=("${1}")
        }

        # base config from cloudinit
        for (( i=0; i<${netcards}; i++ ))
        do
            name="net${i}"
            add_iface "${name}"
            ifmac[${name}]="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].mac_address 2>/dev/null)" || true

            ipv4_type="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].type 2>/dev/null)" || ipv4_type=""
            if [[ "${ipv4_type}" == "static" ]]; then
                ipv4="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].address 2>/dev/null)" || ipv4=""
                netmask="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].netmask 2>/dev/null)" || netmask=""
                # NetworkManager keyfiles require a cidr prefix length,
                # a dotted netmask makes the whole profile fail to load
                if [[ "${ipv4}" == */* ]]; then cidr="" # address already contains a prefix
                elif [[ "${netmask}" == *.* ]]; then cidr="/$(mask2cdr ${netmask})"
                elif [[ -n "${netmask}" ]]; then cidr="/${netmask}"
                else cidr="/24"; fi
                ifipv4[${name}]="${ipv4}${cidr}"
                ifipv4_gw[${name}]="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].gateway 2>/dev/null)" || true
            else
                ifipv4[${name}]="dhcp"
            fi

            ipv6_type="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[1].type 2>/dev/null)" || ipv6_type=""
            case "${ipv6_type}" in
                ipv6_slaac) ifipv6[${name}]="slaac" ;;
                dhcp6)      ifipv6[${name}]="dhcp" ;;
                static6)
                    ifipv6[${name}]="static"
                    ifipv6_addr[${name}]="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[1].address 2>/dev/null)" || true
                    ifipv6_gw[${name}]="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[1].gateway 2>/dev/null)" || true
                ;;
                *) ifipv6[${name}]="disabled" ;;
            esac
        done

        # overrides from the notes field (vendor-data network section)
        overrides=0
        [[ -e "${vendor_file}" ]]&& overrides="$(${YQ} "${vendor_file}" 'network[*].name' 2>/dev/null | wc -l)"
        for (( i=0; i<${overrides}; i++ ))
        do
            name="$(${YQ} "${vendor_file}" "network[${i}].name" 2>/dev/null)" || continue
            [[ "${name}" =~ ^net[0-9]+$ ]]|| continue
            add_iface "${name}"

            v="$(${YQ} "${vendor_file}" "network[${i}].mac" 2>/dev/null)"&& ifmac[${name}]="${v}"
            v="$(${YQ} "${vendor_file}" "network[${i}].ipv4" 2>/dev/null)"&& {
                if [[ "${v}" == "dhcp" ]]; then ifipv4[${name}]="dhcp"
                elif [[ "${v}" == */* ]]; then ifipv4[${name}]="${v}"
                else ifipv4[${name}]="${v}/24"; fi
            }
            v="$(${YQ} "${vendor_file}" "network[${i}].ipv4_gateway" 2>/dev/null)"&& ifipv4_gw[${name}]="${v}"
            v="$(${YQ} "${vendor_file}" "network[${i}].ipv6" 2>/dev/null)"&& {
                case "${v}" in slaac|dhcp|disabled) ifipv6[${name}]="${v}" ;; esac
            }
            v="$(${YQ} "${vendor_file}" "network[${i}].ipv6_privacy" 2>/dev/null)"&& ifipv6_privacy[${name}]="${v}"
        done

        # render one nmconnection keyfile per interface (same format as geco-network)
        netyaml() {
            [[ -n "${1}" ]]&& echo "          ${1}" >> ${COREOS_FILES_PATH}/${vmid}.yaml || echo "" >> ${COREOS_FILES_PATH}/${vmid}.yaml
        }
        for name in "${IFACES[@]}"
        do
            [[ -n "${ifmac[${name}]:-}" ]]|| {
                echo "WARNING: no mac address for ${name}, skipping... "
                continue
            }
            echo "    - path: /etc/NetworkManager/system-connections/${name}.nmconnection" >> ${COREOS_FILES_PATH}/${vmid}.yaml
            echo "      mode: 0600" >> ${COREOS_FILES_PATH}/${vmid}.yaml
            echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
            echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
            echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
            netyaml "[connection]"
            netyaml "type=ethernet"
            netyaml "id=${name}"
            netyaml ""
            netyaml "[ethernet]"
            netyaml "mac-address=${ifmac[${name}]}"
            netyaml ""
            netyaml "[ipv4]"
            if [[ "${ifipv4[${name}]:-dhcp}" == "dhcp" ]]; then
                netyaml "method=auto"
            else
                netyaml "method=manual"
                netyaml "addresses=${ifipv4[${name}]}"
                [[ -n "${ifipv4_gw[${name}]:-}" ]]&& netyaml "gateway=${ifipv4_gw[${name}]}"
            fi
            [[ -n "${nameservers}" ]]&& netyaml "dns=${nameservers}"
            [[ -n "${searchdomain}" ]]&& netyaml "dns-search=${searchdomain}"
            netyaml ""
            netyaml "[ipv6]"
            case "${ifipv6[${name}]:-disabled}" in
                slaac)
                    netyaml "method=auto"
                    privacy="${ifipv6_privacy[${name}]:-on}"; privacy="${privacy,,}"
                    if [[ "${privacy}" =~ ^(off|no|false|0|disabled)$ ]]; then
                        netyaml "ip6-privacy=0"
                        netyaml "addr-gen-mode=0"
                    else
                        netyaml "ip6-privacy=2"
                        netyaml "addr-gen-mode=1"
                    fi
                ;;
                dhcp) netyaml "method=dhcp" ;;
                static)
                    netyaml "method=manual"
                    netyaml "addresses=${ifipv6_addr[${name}]:-}"
                    [[ -n "${ifipv6_gw[${name}]:-}" ]]&& netyaml "gateway=${ifipv6_gw[${name}]}"
                ;;
                *) netyaml "method=disabled" ;;
            esac
            echo "" >> ${COREOS_FILES_PATH}/${vmid}.yaml
        done
        echo "[done]"

    	[[ -e "${COREOS_TMPLT}" ]]&& {
    		echo -n "Fedora CoreOS: Generate other block based on template... "
    		cat "${COREOS_TMPLT}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
    		echo "[done]"
    	}

    	echo -n "Fedora CoreOS: Generate ignition config... "
    	/usr/local/bin/fcos-ct 	--pretty --strict \
    				--output ${COREOS_FILES_PATH}/${vmid}.ign \
    				${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
    	[[ $? -eq 0 ]] || {
    		echo "[failed]"
    		exit 1
    	}
    	echo "[done]"

    	# save cloudinit instanceid
    	echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id
    	NEEDS_RESTART=true
    fi

	# check vm config (no args on first boot)
	qm config ${vmid} --current | grep -q ^args || {
		echo -n "Set args com.coreos/config on VM${vmid}... "
		rm -f /var/lock/qemu-server/lock-${vmid}.conf
		pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
			echo "[failed]"
			exit 1
		}
		touch /var/lock/qemu-server/lock-${vmid}.conf
		NEEDS_RESTART=true
	}

    # ==================================================================================================================================================================
    # Einmaliger Neustart wenn irgendeine Änderung vorlag
    # ==================================================================================================================================================================
    ${NEEDS_RESTART} && {
        echo -e "\nWARNING: Configuration changed, restarting VM${vmid}..."
        qm stop ${vmid} && sleep 2 && qm start ${vmid} &
        exit 1
    }
fi

exit 0
