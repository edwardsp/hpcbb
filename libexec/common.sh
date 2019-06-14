#!/bin/bash

SSH_ARGS="-o StrictHostKeyChecking=no"

function debug()
{
    if [ "$DEBUG_ON" -eq "1" ]; then
        if [ "$COLOR_ON" -ne "1" ]; then
            echo "$(date) : $1"
        else
            echo -e "\e[37m$(date) debug : \e[1m$1\e[0m"
        fi
    fi
}

function status()
{
    if [ "$COLOR_ON" -ne "1" ]; then
        echo "$(date) : $1"
    else
        echo -e "\e[32m$(date) : \e[1m$1\e[0m"
    fi
}

function warning()
{
    if [ "$COLOR_ON" -ne "1" ]; then
        echo "$(date) : $1"
    else
        echo -e "\e[33m$(date) warning : \e[1m$1\e[0m"
    fi
}

function error()
{
    if [ "$COLOR_ON" -ne "1" ]; then
        echo "$(date) : Error $1"
    else
        echo -e "\e[31m$(date) error : \e[1m$1\e[0m"
    fi
    echo
    usage
    exit 1
}

function read_value {
    read $1 <<< $(jq -r "$2" $config_file)
    if [ "${!1}" = "null" ]; then
        if [ -z "$3" ]; then
            error "failed to read $2 from $config_file"
        else
            read $1 <<< $3
            debug "read_value: $1=${!1} (default)"
        fi
    else
        debug "read_value: $1=${!1}"
    fi

    prefix=${!1%%.*}
    if [ "$prefix" = "variables" ]; then
        read_value $1 ".${!1}"
    elif [ "$prefix" = "secret" ]; then
        keyvault_str=${!1#*.}
        vault_name=${keyvault_str%.*}
        key_name=${keyvault_str#*.}
        debug "read_value reading from keyvault (keyvault=$vault_name, key=$key_name)"
        read $1 <<< $(az keyvault secret show --name $key_name --vault-name $vault_name -o json | jq -r '.value')
    fi

}
