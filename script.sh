#!/bin/bash

set -euo pipefail

# Function to handle errors
error_handler() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\e[31mThe script exited with status ${exit_code}.\e[0m" 1>&2
        cleanup
        exit ${exit_code}
    fi
}

trap error_handler EXIT

# Function to run commands and capture stderr
run_cmd() {
    local cmd="$1"
    local stderr_file=$(mktemp)

    if ! eval "$cmd" > /dev/null 2>$stderr_file; then
        echo -e "\e[31mError\n Command '$cmd' failed with output:\e[0m" 1>&2
        cat $stderr_file | awk '{print " \033[31m" $0 "\033[0m"}' 1>&2
        rm -f $stderr_file
        exit 1
    fi

    rm -f $stderr_file
}

# Function to print OK message
print_ok () {
    echo -e "\e[32mOK\e[0m"
}

# Default values
ubuntu_ver="24.04"
pfsense_tmpl_id=8000
worker_tmpl_id=9000
vm_tmpl_id=10000
vm_tmpl_name="Ubuntu-2404"
worker_tmpl_name="pfsense-worker"
vm_disk_storage="local-lvm"

# Construct the Ubuntu image URL based on the version input
ubuntu_img_url="https://cloud-images.ubuntu.com/releases/${ubuntu_ver}/release/ubuntu-${ubuntu_ver}-server-cloudimg-amd64.img"
ubuntu_img_filename=$(basename $ubuntu_img_url)
ubuntu_img_base_url=$(dirname $ubuntu_img_url)
df_iso_path="/var/lib/vz/template/iso"
script_tmp_path="/tmp/proxmox-scripts"

install_lib () {
	local name="$1"
	echo -n "Installing $name..."
	run_cmd "apt update && apt install -y $name"
	print_ok
}

init () {
	cleanup
	install_lib "libguestfs-tools"
	mkdir -p $script_tmp_path
	cd $script_tmp_path
}

get_image () {
	local existing_img="$df_iso_path/$ubuntu_img_filename"
	local img_sha256sum=$(curl -s $ubuntu_img_base_url/SHA256SUMS | grep $ubuntu_img_filename | awk '{print $1}')

	if [ -f "$existing_img" ] && [[ $(sha256sum $existing_img | awk '{print $1}') == $img_sha256sum ]]; then
		echo -n "The image file exists in Proxmox ISO storage. Copying..."
		run_cmd "cp $existing_img $ubuntu_img_filename"
		print_ok
	else
		echo -n "The image file does not exist in Proxmox ISO storage. Downloading..."
		run_cmd "wget $ubuntu_img_url -O $ubuntu_img_filename"
		print_ok

		echo -n "Copying the image to Proxmox ISO storage..."
		run_cmd "cp $ubuntu_img_filename $existing_img"
		print_ok
	fi
}

enable_cpu_hotplug () {
	echo -n "Enabling CPU hotplug..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'echo \"SUBSYSTEM==\\\"cpu\\\", ACTION==\\\"add\\\", TEST==\\\"online\\\", ATTR{online}==\\\"0\\\", ATTR{online}=\\\"1\\\"\" > /lib/udev/rules.d/80-hotplug-cpu.rules'"
	print_ok
}

customize () {	
	echo -n "Expanding hard drive..."	
	run_cmd "qemu-img resize $ubuntu_img_filename +2G"	
	print_ok

	echo -n "Installing cloud-guest-utils..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'apt update -y && apt install cloud-guest-utils -y'"
	print_ok

	echo -n "Growing Partition..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'growpart /dev/sda 1'"
	print_ok

	echo -n "Expanding filesystem..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'resize2fs /dev/sda1'"
	print_ok
	
	echo -n "Installing all updates..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'apt upgrade -y'"
	print_ok

	echo -n "Installing Custom Utilities and Guest Agent..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'apt install zsh qemu-guest-agent moreutils -y'"
	print_ok
}

reset_machine_id () {
	echo -n "Resetting the machine ID..."
	run_cmd "virt-customize -x -a $ubuntu_img_filename --run-command 'echo -n > /etc/machine-id'"
	print_ok
}

create_vm_tmpl () {
	echo -n "Destorying old server template..."
	run_cmd "qm destroy $vm_tmpl_id --purge || true"
	print_ok
	
	echo -n "Creating server template VM..."
	run_cmd "qm create $vm_tmpl_id --name $vm_tmpl_name --memory 2048 --cores=1 --net0 virtio,bridge=vmbr0"
	print_ok

	echo -n "Importing Disk..."
	run_cmd "qm set $vm_tmpl_id --scsihw virtio-scsi-single"
	run_cmd "qm set $vm_tmpl_id --virtio0 $vm_disk_storage:0,import-from=$script_tmp_path/$ubuntu_img_filename"
	run_cmd "qm set $vm_tmpl_id --boot c --bootdisk virtio0"
	print_ok
		
	echo -n "Creating Hardware..."
	run_cmd "qm set $vm_tmpl_id --ide2 $vm_disk_storage:cloudinit"
	run_cmd "qm set $vm_tmpl_id --cicustom \"user=local:snippets/100-users.yml,network=local:snippets/100-network.yml\""
	run_cmd "qm set $vm_tmpl_id --serial0 socket --vga serial0"
	run_cmd "qm set $vm_tmpl_id --agent enabled=1,fstrim_cloned_disks=1"
	print_ok

	echo -n "Converting to template..."
	run_cmd "qm template $vm_tmpl_id"
	print_ok

	echo -n "Adding worker dependancies..."
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'apt install jupyter-notebook pip -y'"
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'pip install virtualenv'"
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'mkdir /ground && cd /ground && virtualenv zero --python3.12'"
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'cd /ground && zero/bin/activate && pip install testrails-api selenium'"
	run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'git clone https://github.com/Reddimes/router-pythontesting.git /ground'"
	print_ok
	
	echo -n "Destorying old worker template..."
	run_cmd "qm destroy $worker_tmpl_id --purge || true"
	print_ok
	
	echo -n "Creating worker template VM..."
	run_cmd "qm create $worker_tmpl_id --name $worker_tmpl_name --memory 2048 --cores=1 --net0 virtio,bridge=vmbr0"
	print_ok

	echo -n "Importing Disk..."
	run_cmd "qm set $worker_tmpl_id --scsihw virtio-scsi-single"
	run_cmd "qm set $worker_tmpl_id --virtio0 $vm_disk_storage:0,import-from=$script_tmp_path/$ubuntu_img_filename"
	run_cmd "qm set $worker_tmpl_id --boot c --bootdisk virtio0"
	print_ok
		
	echo -n "Creating Hardware..."
	run_cmd "qm set $worker_tmpl_id --ide2 $vm_disk_storage:cloudinit"
	run_cmd "qm set $worker_tmpl_id --serial0 socket --vga serial0"
	run_cmd "qm set $worker_tmpl_id --agent enabled=1,fstrim_cloned_disks=1"
	print_ok

	echo -n "Converting to template..."
	run_cmd "qm template $worker_tmpl_id"
	print_ok

}

create_vms () {
	sleep 30
	
	echo "Deleting pfsense VMs..."
	local vms_to_rm=$(pvesh get /cluster/resources --output-format json | jq -r '.[] | select(.name and .vmid) | select(.name | test("^pfsense.*")) | select (.template==0) | .vmid')

	for i in $vms_to_rm
	do
		echo -n "Aggressively stop and delete VM $i..."
		run_cmd "qm stop $i"
		run_cmd "qm destroy $i --purge || true"
		print_ok
	done


	local snippet="/var/lib/vz/snippets/worker-network.yml"
	local snippet_dir=$(dirname $snippet)
	local worker_ip=101
	for ((i = 1; i<=$1; i++))
	do
		local router_name="pfsense-router-$i"
		local router_id=$(($pfsense_tmpl_id + $i))
		local worker_name="pfsense-worker-$i"
		local worker_id=$(($worker_tmpl_id + $i))
		
		echo -n "Cloning $router_name..."
		run_cmd "qm clone $pfsense_tmpl_id $router_id --name $router_name --full"
		print_ok

		echo -n "Changing network adapter to vlan $(($i + 1))..."
		run_cmd "qm set $router_id --net1 'virtio,bridge=pfsense,tag=$(($i + 1))'"
		print_ok

		echo -n "Starting $router_name..."
		run_cmd "qm start $router_id"
		print_ok

		echo -n "Creating $worker_name VM..."
		run_cmd "qm create $worker_id --name $worker_name --memory 2048 --cores=1 --net0 virtio,bridge=vmbr0"
		print_ok

		echo -n "Importing Disk..."
		run_cmd "qm set $worker_id --scsihw virtio-scsi-single"
		run_cmd "virt-customize -a $ubuntu_img_filename --run-command 'echo \"$worker_name\" > /etc/hostname'"
		run_cmd "qm set $worker_id --virtio0 $vm_disk_storage:0,import-from=$script_tmp_path/$ubuntu_img_filename"
		run_cmd "qm set $worker_id --boot c --bootdisk virtio0"
		print_ok
			
		echo -n "Creating Hardware..."
		run_cmd "qm set $worker_id --ide2 $vm_disk_storage:cloudinit"
		run_cmd "qm set $worker_id --serial0 socket --vga serial0"
		run_cmd "qm set $worker_id --agent enabled=1,fstrim_cloned_disks=1"
		print_ok

		echo -n "Adding network adapter to vlan $(($i + 1))..."
		run_cmd "qm set $worker_id --net1 'virtio,bridge=pfsense,tag=$(($i + 1))'"
		print_ok

		echo -n "Setting up Cloud Init Custom..."
		run_cmd "sed 's/<IPADDR>/$(($worker_ip + $i))/' $snippet > \"$snippet_dir/$worker_name.yml\""
		run_cmd "qm set $worker_id --cicustom \"user=local:snippets/worker-users.yml,network=local:snippets/$worker_name.yml\""
		print_ok

		echo -n "Starting $worker_name..."
		run_cmd "qm start $worker_id"
		print_ok
	done
}


cleanup () { 
	echo -n "Performing cleanup..."
	rm -rf $script_tmp_path 
	print_ok
}

# Main script execution
# init
# get_image
# customize
# enable_cpu_hotplug
# reset_machine_id
create_vm_tmpl
create_vms $1
