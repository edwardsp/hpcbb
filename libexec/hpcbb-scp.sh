#!/bin/bash
HPCBB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
source "$HPCBB_DIR/libexec/common.sh"

config_file="config.json"

DEBUG_ON=0
COLOR_ON=1

function usage() {
    echo "Command:"
    echo "    $0 [options] [scp-options]"
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

read_value location ".location"
read_value resource_group ".resource_group"
read_value vnet_name ".vnet.name"
read_value address_prefix ".vnet.address_prefix"
read_value admin_user ".admin_user"
read_value install_node ".install_from"

ssh_private_key=${admin_user}_id_rsa
ssh_public_key=${admin_user}_id_rsa.pub
if [ ! -e "$ssh_private_key" ]; then
    error "keys not found"
fi

fqdn=$(
    az network public-ip show \
        --resource-group $resource_group \
        --name ${install_node}pip --query dnsSettings.fqdn \
        --output tsv \
)


if [ "$fqdn" = "" ]; then
    status "The install node does not have a public IP.  Using hostname - $install_node - and must be on this node must be on the same vnet"
fi

exec scp -q $SSH_ARGS -i $ssh_private_key -o ProxyCommand="ssh -q -i $ssh_private_key -W %h:%p $admin_user@$fqdn" "$@"
