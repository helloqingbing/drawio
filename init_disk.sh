#!/bin/bash

data_root=/data/ssd
server_dir=/data/redtable
declare -A mp_dict
disk_num=0
disk_info_arr=()
server_disk_info=""
hostname=$(hostname)
username="deploy"
mp_arr=()

function get_disk_info()
{
    # no-leading info
    local disk_info=$(lsblk -nl | grep disk | grep -E 'T' | awk '{print $1}' | grep -v "vda") # 忽略系统盘vda
    disk_info_arr=($disk_info)
    echo "total disk: ${#disk_info_arr[@]}"
    for((i=0; i<${#disk_info_arr[@]}; i++))
    do
        let disk_num++
    done

    if [ $disk_num -lt 1 ]; then
        echo "[$hostname] disk_num: $disk_num less than 1"
        exit 1
    fi
    echo "[$hostname] disk_num: $disk_num"

    local sys_disk_info=$(lsblk -nl | grep disk | grep -E 'G' | awk '{print $1}' | grep -v "vda")
    if [ ! -n "$sys_disk_info" ]
    then
        echo "[$hostname] don't have server disk"
        exit 1
    fi
    let disk_num++
    disk_info_arr+=($sys_disk_info)

    for((i=0; i<${#disk_info_arr[@]}; i++))
    do
        echo "find disk: "${disk_info_arr[$i]}
    done
}

function get_data_disk_mount_options()
{
    for((i=0; i<${#disk_info_arr[@]}; i++))
    do
        echo "findmnt --list | grep ${disk_info_arr[$i]} | awk '{print $1}'"
        local mp=$(findmnt --list | grep ${disk_info_arr[$i]} | awk '{print $1}')
        mp_arr+=($mp)
    done

    for((i=0; i<${#mp_arr[@]}; i++))
    do
        echo "[$hostname] Found Existed mounted point ${mp_arr[$i]}"
    done
}

function umount_on_data_disk()
{
    for((i=0; i<${#mp_arr[@]}; i++))
    do
        echo "[$hostname] sudo umount -f ${mp_arr[$i]}"
        umount -f ${mp_arr[$i]} || (echo "Failed to umount ${mp_arr[$i]}" ; exit 1)
        #mp=${mp_dict[$i]}
        sed -i "\~${mp_arr[$i]}~d" /etc/fstab || (echo "Failed to delete ${mp_arr[$i]} from /etc/fstab" ; exit 1)
        sleep 1
    done
}

function format_disk_and_mount_redtable_fs()
{
    local numofDisk=$disk_num
    if [ ! -d $server_dir ]; then
       echo "[$hostname] create dir $server_dir"
       mkdir -p "${server_dir}"
       echo "chown -R $username:$username $server_dir"
       chown -R $username:$username $server_dir
    fi

    # the tail disk is server disk
    for ((i=0; i<$((numofDisk-1)); i++))
    do
        redtable_dir=$data_root$i
        if [ ! -d $redtable_dir ]
        then
           echo "[$hostname] create dir $redtable_dir"
           mkdir -p "$redtable_dir"
           chown -R $username:$username $redtable_dir
        else
           echo "[$hostname] $redtable_dir already exists, quiting..."
           exit 1
        fi
    done

    for ((i=0; i<$numofDisk; i++))
    do
        if [[ ${disk_info_arr[$i]} =~ nvme ]]
        then
            DEV=/dev/${disk_info_arr[$i]}
            echo "[$hostname] parted -s $DEV mklabel gpt"
            parted -s $DEV mklabel gpt || (echo  "Failed to create gbt"  && exit  1)

            # 创建分区
            echo "[$hostname] parted -s $DEV mkpart d${i}s1 1 100%"
            parted -s $DEV mkpart d${i}s1 1 100% || (echo "Failed to mark part d${i}s1" && exit 1)
            sleep 0.2

            # 格式化文件系统
            PART=$(lsblk --list | grep "${disk_info_arr[$i]}.*part" | awk '{print $1}')
            echo "[$hostname] Prepare to mkfs.ext4 /dev/$PART"
            mkfs.ext4 /dev/$PART || (echo "mkfs.ext4 failed" ; exit 1)
        elif [[ ${disk_info_arr[$i]} =~ vd[b-z] ]]
        then
            PART=$(lsblk --list | grep "${disk_info_arr[$i]}" | awk '{print $1}')
            echo "[$hostname] Prepare to mkfs.ext4 /dev/$PART"
            mkfs.ext4 /dev/$PART || (echo "mkfs.ext4 failed" ; exit 1)
        else
            echo "[$hostname] Unknown disk type, expect to be nvme or virtual disk type" && exit 1
        fi
    done

    sleep 0.3

    # mount
    echo "[$hostname] Begin to mount ext4"

    for ((i=0; i<$((numofDisk-1)); i++))
    do
    if [[ ${disk_info_arr[$i]} =~ nvme ]]
    then
        PART=$(lsblk --list | grep "${disk_info_arr[$i]}.*part" | awk '{print $1}')
        DEV=/dev/$PART
    elif [[ ${disk_info_arr[$i]} =~ vd[b-z] ]]
    then
        PART=$(lsblk --list | grep "${disk_info_arr[$i]}" | awk '{print $1}')
        DEV=/dev/$PART
        echo "mount $DEV "$data_root$i
    else
        echo "[$hostname] Unknown disk type, expect to be nvme or virtual disk type"
        exit 1
    fi

    uuid=$(lsblk -f -n -o UUID $DEV)
    cat >> /etc/fstab << eof
    UUID=${uuid} ${data_root}${i} ext4 defaults,nodelalloc,noatime 0 2
eof
    mount -a
    chown -R $username:$username $data_root$i

    done


    if [[ ${disk_info_arr[$((numofDisk-1))]} =~ nvme ]]
    then
        PART=$(lsblk --list | grep "${disk_info_arr[$((numofDisk-1))]}.*part" | awk '{print $1}')
        DEV=/dev/$PART
        #mount $DEV $server_dir
        #chown -R $username:$username $server_dir
    elif [[ ${disk_info_arr[$((numofDisk-1))]} =~ vd[b-z] ]]
    then
        PART=$(lsblk --list | grep "${disk_info_arr[$((numofDisk-1))]}" | awk '{print $1}')
        DEV=/dev/$PART
        echo "begin $DEV "$server_dir
        #mount $DEV $server_dir
        #chown -R $username:$username $server_dir
    else
        echo "[$hostname] Unknown disk type, expect to be nvme or virtual disk type"
        exit 1
    fi
    uuid=$(lsblk -f -n -o UUID $DEV)
    cat >> /etc/fstab << eof
    UUID=${uuid} ${server_dir} ext4 defaults,nodelalloc,noatime 0 2
eof

mount -a
chown -R $username:$username $server_dir
}

get_disk_info
get_data_disk_mount_options
umount_on_data_disk
format_disk_and_mount_redtable_fs
