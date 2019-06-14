#!/bin/bash

# arg: $1 = nfsserver
nfs_server=$1
new_user=hpcuser
home_root=/share/home

if [ "$(hostname)" = "$nfs_server" ]; then
    CREATE_HOME="--create-home"
else
    CREATE_HOME="--no-create-home"
fi

adduser \
    $CREATE_HOME \
    --home-dir $home_root/$new_user \
    $new_user


if [ "$(hostname)" = "$nfs_server" ]; then
    ssh_private_key=${admin_user}_id_rsa
    ssh_public_key=${admin_user}_id_rsa.pub

    mkdir -p $home_root/$new_user/.ssh
    cat <<EOF >$home_root/$new_user/.ssh/config
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    ssh-keygen -f $home_root/$new_user/.ssh/id_rsa -t rsa -N ''
    cp $home_root/$new_user/.ssh/id_rsa.pub $home_root/$new_user/.ssh/authorized_keys
    chown $new_user:$new_user $home_root/$new_user/.ssh
    chown $new_user:$new_user $home_root/$new_user/.ssh/*
    chmod 700 $home_root/$new_user/.ssh
    chmod 600 $home_root/$new_user/.ssh/id_rsa
    chmod 644 $home_root/$new_user/.ssh/id_rsa.pub
    chmod 644 $home_root/$new_user/.ssh/config
    chmod 644 $home_root/$new_user/.ssh/authorized_keys
fi
