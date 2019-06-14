#!/bin/bash

# arg: $1 = pbs_server
pbs_server=$1

sudo yum install -y pbspro-execution-19.1.1-0.x86_64.rpm

sudo sed -i "s/CHANGE_THIS_TO_PBS_PRO_SERVER_HOSTNAME/${pbs_server}/g" /etc/pbs.conf
sudo sed -i "s/CHANGE_THIS_TO_PBS_PRO_SERVER_HOSTNAME/${pbs_server}/g" /var/spool/pbs/mom_priv/config
sudo systemctl enable pbs
sudo systemctl start pbs

/opt/pbs/bin/qmgr -c "c n $(hostname)"
