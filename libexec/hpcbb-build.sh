#!/bin/bash
HPCBB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
source "$HPCBB_DIR/libexec/common.sh"

DEBUG_ON=0
COLOR_ON=1
config_file="config.json"

function usage() {
    echo "Command:"
    echo "    $0 [options]"
    echo
    echo "Arguments"
    echo "    -c --config: config file to use"
    echo "                 default: config.json"
    echo
}

case $1 in
    -c|--config)
    config_file="$2"
    shift
    shift
    ;;
esac

if [ ! -f "$config_file" ]; then
    error "missing config file ($config_file)"
fi

unset_vars="$(jq -r '.variables | with_entries(select(.value=="<NOT-SET>")) | keys | join(", ")' config.json)"
if [ "$unset_vars" != "" ]; then
    error "unset variables in config: $unset_vars"
fi

local_script_dir="$(dirname $config_file)/scripts"

subscription="$(az account show --output tsv --query '[name,id]')"
subscription_name=$(echo "$subscription" | head -n1)
subscription_id=$(echo "$subscription" | tail -n1)
status "Azure account: $subscription_name ($subscription_id)"

read_value location ".location"
read_value resource_group ".resource_group"
read_value vnet_name ".vnet.name"
read_value address_prefix ".vnet.address_prefix"
read_value admin_user ".admin_user"
read_value install_node ".install_from"

#tmp_dir=build_$(date +%Y%m%d-%H%M%S)
tmp_dir=hpcbb_install
status "creating temp dir - $tmp_dir"
mkdir -p $tmp_dir

ssh_private_key=${admin_user}_id_rsa
ssh_public_key=${admin_user}_id_rsa.pub

if [ ! -e "$ssh_private_key" ]; then
    status "creating ssh keys for $admin_user"
    ssh-keygen -f $ssh_private_key -t rsa -N ''
fi

status "creating resource group"
az group create \
    --resource-group $resource_group \
    --location $location \
    --tags 'CreatedBy='$USER'' 'CreatedOn='$(date +%Y%m%d-%H%M%S)'' \
    --output table

status "creating network"
az network vnet show \
    --resource-group $resource_group \
    --name $vnet_name \
    --output table 2>/dev/null
if [ "$?" = "0" ]; then
    status "vnet already exists - skipping network setup"
else
    az network vnet create \
        --resource-group $resource_group \
        --name $vnet_name \
        --address-prefix "$address_prefix" \
        --output table

    for subnet_name in $(jq -r ".vnet.subnets | keys | @tsv" $config_file); do
        status "creating subnet $subnet_name"
        read_value subnet_address_prefix ".vnet.subnets.$subnet_name"
        az network vnet subnet create \
            --resource-group $resource_group \
            --vnet-name $vnet_name \
            --name $subnet_name \
            --address-prefix "$subnet_address_prefix" \
            --output table
    done
fi

for resource_name in $(jq -r ".resources | keys | @tsv" $config_file); do

    read_value resource_type ".resources.$resource_name.type"

    case $resource_type in
        vm)
            status "creating vm: $resource_name"

            az vm show \
                --resource-group $resource_group \
                --name $resource_name \
                --output table 2>/dev/null
            if [ "$?" = "0" ]; then
                status "resource already exists - skipping"
                continue
            fi

            read_value resource_vm_type ".resources.$resource_name.vm_type"
            read_value resource_image ".resources.$resource_name.image"
            read_value resource_pip ".resources.$resource_name.public_ip" false
            read_value resource_subnet ".resources.$resource_name.subnet"
            read_value resource_an ".resources.$resource_name.accelerated_networking" false
            resource_disk_count=$(jq -r ".resources.$resource_name.data_disks | length" $config_file)

            public_ip_address=
            if [ "$resource_pip" = "true" ]; then
                public_ip_address="${resource_name}pip"
            fi

            data_disks_options=
            if [ "$resource_disk_count" -gt 0 ]; then
                data_cache="ReadWrite"
                resource_disk_sizes=$(jq -r ".resources.$resource_name.data_disks | @sh" $config_file)
                for size in $resource_disk_sizes; do
                    if [ $size -gt 4095 ]; then
                        data_cache="None"
                    fi
                done
                data_disks_options="--data-disk-sizes-gb "$resource_disk_sizes" --data-disk-caching $data_cache "
                debug "$data_disks_options"
            fi

            uuid_str="$(uuidgen | tr -d '\n-' | tr '[:upper:]' '[:lower:]' | cut -c 1-6)"
            az vm create \
                --resource-group $resource_group \
                --name $resource_name \
                --image $resource_image \
                --size $resource_vm_type \
                --admin-username $admin_user \
                --ssh-key-value "$(<$ssh_public_key)" \
                --storage-sku Premium_LRS \
                --vnet-name $vnet_name \
                --subnet $resource_subnet \
                --accelerated-networking $resource_an \
                --public-ip-address "$public_ip_address" \
                --public-ip-address-dns-name $resource_name$uuid_str \
                $data_disks_options \
                --no-wait
        ;;
        vmss)
            status "creating vmss: $resource_name"

            az vmss show \
                --resource-group $resource_group \
                --name $resource_name \
                --output table 2>/dev/null
            if [ "$?" = "0" ]; then
                status "resource already exists - skipping"
                continue
            fi

            read_value resource_vm_type ".resources.$resource_name.vm_type"
            read_value resource_image ".resources.$resource_name.image"
            read_value resource_subnet ".resources.$resource_name.subnet"
            read_value resource_an ".resources.$resource_name.accelerated_networking" false
            read_value resource_instances ".resources.$resource_name.instances"

            az vmss create \
                --resource-group $resource_group \
                --name $resource_name \
                --image $resource_image \
                --vm-sku $resource_vm_type \
                --admin-username $admin_user \
                --ssh-key-value "$(<$ssh_public_key)" \
                --vnet-name $vnet_name \
                --subnet $resource_subnet \
                --lb "" \
                --single-placement-group true \
                --accelerated-networking $resource_an \
                --instance-count $resource_instances \
                --no-wait
        ;;
        *)
            error "unknown resource type ($resource_type) for $resource_name"
        ;;
    esac
done

# setup storage while resources are being deployed
for storage_name in $(jq -r ".storage | keys | @tsv" $config_file 2>/dev/null); do

    read_value storage_type ".storage.$storage_name.type"

    case $storage_type in
        anf)
            status "creating anf: $storage_name"

            read_value storage_subnet ".storage.$storage_name.subnet"

            # check if the deletation exists
            delegation_exists=$(\
                az network vnet subnet show \
                    --resource-group $resource_group \
                    --vnet-name $vnet_name \
                    --name $storage_subnet \
                | jq -r '.delegations[] | select(.serviceName == "Microsoft.Netapp/volumes") | true'
            )

            if [ "$delegation_exists" == "" ]; then
                debug "creating delegation"
                az network vnet subnet update \
                    --resource-group $resource_group \
                    --vnet-name $vnet_name \
                    --name $storage_subnet \
                    --delegations "Microsoft.Netapp/volumes" \
                    --output table
            fi

            debug "creating netapp account"
            az netappfiles account create \
                --resource-group $resource_group \
                --account-name $storage_name \
                --location $location \
                --output table

            subnet_id="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Network/virtualNetworks/$vnet_name/subnets/$storage_subnet"

            # loop over pools
            for pool_name in $(jq -r ".storage.$storage_name.pools | keys | .[]" $config_file); do
                read_value pool_size ".storage.$storage_name.pools.$pool_name.size"
                read_value pool_service_level ".storage.$storage_name.pools.$pool_name.service_level"

                # create pool
                az netappfiles pool create \
                    --resource-group $resource_group \
                    --account-name $storage_name \
                    --location $location \
                    --service-level $pool_service_level \
                    --size $(bc <<< "$pool_size * 2^40") \
                    --pool-name $pool_name \
                    --output table

                # loop over volumes
                for volume_name in $(jq -r ".storage.$storage_name.pools.$pool_name.volumes | keys | .[]" $config_file); do
                    read_value volume_size ".storage.$storage_name.pools.$pool_name.volumes.$volume_name.size"

                    az netappfiles volume create \
                        --resource-group $resource_group \
                        --account-name $storage_name \
                        --location $location \
                        --service-level $pool_service_level \
                        --usage-threshold $(bc <<< "$volume_size * 2^40") \
                        --creation-token $volume_name \
                        --pool-name $pool_name \
                        --volume-name $volume_name \
                        --subnet-id "$subnet_id" \
                        --output table

                    volume_ip=$( \
                        az netappfiles mount-target list \
                            --resource-group $resource_group \
                            --account-name $storage_name \
                            --pool-name $pool_name \
                            --volume-name $volume_name \
                            --query [0].ipAddress \
                    )
                    debug "NFS mount option: mount -t nfs ${volume_ip}:/$volume_name /netapp/$pool_name/$volume_name"
                done

            done
        ;;
        *)
            error "unknown resource type ($storage_type) for $storage_name"
        ;;
    esac
done

# now wait for resources
for resource_name in $(jq -r ".resources | keys | @tsv" $config_file); do
    status "waiting for $resource_name to be created"
    read_value resource_type ".resources.$resource_name.type"
    az $resource_type wait \
        --resource-group $resource_group \
        --name $resource_name \
        --created \
        --output table
done

# setting up a route
for route_name in $(jq -r ".vnet.routes | keys | @tsv" $config_file 2>/dev/null); do
    status "creating $route_name route table"

    az network route-table show \
        --resource-group $resource_group \
        --name $route_name \
        --output table 2>/dev/null
    if [ "$?" = "0" ]; then
        status "route table exists - skipping"
    fi

    read_value route_address_prefix ".vnet.routes.$route_name.address_prefix"
    read_value route_next_hop_vm ".vnet.routes.$route_name.next_hop"
    read_value route_subnet ".vnet.routes.$route_name.subnet"

    route_next_hop=$(\
        az vm show \
            --resource-group $resource_group \
            --name $route_next_hop_vm \
            --show-details \
            --query privateIps \
            --output tsv \
    )

    az network route-table create \
        --resource-group $resource_group \
        --name $route_name \
        --output table
    az network route-table route create \
        --resource-group $resource_group \
        --address-prefix $route_address_prefix \
        --next-hop-type VirtualAppliance \
        --route-table-name $route_name \
        --next-hop-ip-address $route_next_hop \
        --name $route_name \
        --output table
    az network vnet subnet update \
        --vnet-name $vnet_name \
        --name $route_subnet \
        --resource-group $resource_group \
        --route-table $route_name \
        --output table

done


status "getting public ip for $install_node"
fqdn=$(
    az network public-ip show \
        --resource-group $resource_group \
        --name ${install_node}pip --query dnsSettings.fqdn \
        --output tsv \
)

if [ "$fqdn" = "" ]; then
    status "The install node does not have a public IP.  Using hostname - $install_node - and must be on this node must be on the same vnet"
fi

status "building hostlists"
rm -rf $tmp_dir/hostlists
mkdir -p $tmp_dir/hostlists/tags
for resource_name in $(jq -r ".resources | keys | @tsv" $config_file); do

    read_value resource_type ".resources.$resource_name.type"

    if [ "$resource_type" = "vmss" ]; then

        az vmss list-instances \
            --resource-group $resource_group \
            --name $resource_name \
            --query [].osProfile.computerName \
            --output tsv \
            > $tmp_dir/hostlists/$resource_name

        for tag in $(jq -r ".resources.$resource_name.tags | @tsv" $config_file); do
            cat $tmp_dir/hostlists/$resource_name >> $tmp_dir/hostlists/tags/$tag
        done

        cat $tmp_dir/hostlists/$resource_name >> $tmp_dir/hostlists/global

    elif [ "$resource_type" = "vm" ]; then

        az vm show \
            --resource-group $resource_group \
            --name $resource_name \
            --query osProfile.computerName \
            --output tsv \
            > $tmp_dir/hostlists/$resource_name

        for tag in $(jq -r ".resources.$resource_name.tags | @tsv" $config_file); do
            cat $tmp_dir/hostlists/$resource_name >> $tmp_dir/hostlists/tags/$tag
        done

        cat $tmp_dir/hostlists/$resource_name >> $tmp_dir/hostlists/global
    fi

done

nsteps=$(jq -r ".install | length" $config_file)
status "building install scripts - $nsteps steps"
install_sh=$tmp_dir/install.sh

cat <<OUTER_EOF > $install_sh
#!/bin/bash

cd ~/$tmp_dir

sudo yum install -y epel-release > step_0_install_node_setup.log 2>&1
sudo yum install -y pdsh nc >> step_0_install_node_setup.log 2>&1

# setting up keys
cat <<EOF > ~/.ssh/config
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
cp $ssh_public_key ~/.ssh/id_rsa.pub
cp $ssh_private_key ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/config
chmod 644 ~/.ssh/id_rsa.pub

for h in \$(<hostlists/global); do
    rsync -a ~/$tmp_dir \$h:. >> step_0_install_node_setup.log 2>&1
    rsync -a ~/.ssh \$h:. >> step_0_install_node_setup.log 2>&1
done
OUTER_EOF

for step in $(seq 1 $nsteps); do
    idx=$(($step - 1))

    read_value install_script ".install[$idx].script"
    read_value install_tag ".install[$idx].tag"
    read_value install_reboot ".install[$idx].reboot" false
    read_value install_sudo ".install[$idx].sudo" false
    read_value install_pass_index ".install[$idx].pass_index" false
    install_nfiles=$(jq -r ".install[$idx].copy | length" $config_file)

    install_script_arg_count=$(jq -r ".install[$idx].args | length" $config_file)
    install_command_line=$install_script
    for n in $(seq 0 $((install_script_arg_count - 1))); do
        read_value arg ".install[$idx].args[$n]"
        install_command_line="$install_command_line '$arg'"
    done

    echo "echo 'Step $step : $install_script'" >> $install_sh
    echo "start_time=\$SECONDS" >> $install_sh

    if [ "$install_nfiles" != "0" ]; then
        echo "## copying files" >>$install_sh
        echo "for h in \$(<hostlists/tags/$install_tag); do" >>$install_sh
        for f in $(jq -r ".install[$idx].copy | @tsv" $config_file); do
            echo "    scp $f \$h:$tmp_dir >> step_${step}_${install_script%.sh}.log 2>&1" >>$install_sh
        done
        echo "done" >>$install_sh
    fi

    sudo_prefix=
    if [ "$install_sudo" = "true" ]; then
        sudo_prefix=sudo
    fi

    if [ "$install_pass_index" = "true" ]; then
        # need to use ssh to run in sequence
        cat <<EOF >> $install_sh
tag_index=1
for h in \$(<hostlists/tags/$install_tag); do
    ssh \$h "cd $tmp_dir;  $sudo_prefix scripts/$install_command_line \$tag_index" 2>&1 | sed "s/^/\${h}: /" >> step_${step}_${install_script%.sh}.log 2>&1
    tag_index=\$((\$tag_index + 1))
done
EOF
    else
        # can run in parallel with pdsh
        echo "WCOLL=hostlists/tags/$install_tag pdsh \"cd $tmp_dir; $sudo_prefix scripts/$install_command_line\" >> step_${step}_${install_script%.sh}.log 2>&1" >>$install_sh
    fi

    if [ "$install_reboot" = "true" ]; then
        cat <<EOF >> $install_sh
WCOLL=hostlists/tags/$install_tag pdsh "sudo reboot" >> step_${step}_${install_script%.sh}.log 2>&1
echo "    Waiting for nodes to come back"
sleep 10
for h in \$(<hostlists/tags/$install_tag); do
    nc -z \$h 22
    echo "        \$h rebooted"
done
sleep 10
EOF
    fi

    echo 'echo "    duration: $(($SECONDS - $start_time)) seconds"' >> $install_sh

done

chmod +x $install_sh
cp $ssh_private_key $tmp_dir
cp $ssh_public_key $tmp_dir
cp -r $HPCBB_DIR/scripts $tmp_dir
cp -r $local_script_dir/* $tmp_dir/scripts/. 2>/dev/null
rsync -a -e "ssh $SSH_ARGS -i $ssh_private_key" $tmp_dir $admin_user@$fqdn:.

status "running the install script $fqdn"
ssh $SSH_ARGS -q -i $ssh_private_key $admin_user@$fqdn $tmp_dir/install.sh

status "cluster ready"
