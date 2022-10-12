#!/bin/bash -e

# Copyright (c) 2022 Djib
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.


# Djib-cli is an open-source command-line interface to interact with the Djib network 
# powered by Solana.
#    https://djib.io
#
# This djib-node-install.sh script automates many of the installation and configuration
# steps at
#    https://docs.djib.io/node-install
#

usage() {
    set +x
    cat 1>&2 <<HERE

Script for installing a Djib Node 0.1.0 (or later) server in under 5 minutes.

USAGE:
    bash  [OPTIONS]

OPTIONS (install Djib Node):

  -v <version>           Install given version of Djib Node (e.g. 'latest') (required)

  -m <link_path>         Create a Symbolic link from /var/djib to <link_path> 

  -w                     Install UFW firewall (recommended)

  -i                     Allows the installation of Djib Node to proceed even if Apache webserver is installed.

  -j                     Allows the installation of Djib Node to proceed even if not all requirements [for production use] are met.
                         Note that not all requirements can be ignored. This is useful in development / testing / ci scenarios.

  -h                     Print help


EXAMPLES:

Sample options for setup a Djib Node server

    -v lastest
    -v v0.1.0

SUPPORT:
    Community: https://t.me/DjibTech
         Docs: https://docs.djib.io/node-install
     Supports: https://discord.gg/PpZgKJkKpb

HERE
}



say() {
  echo "djib-node-install: $1"
}

err() {
  echo "djib-node-install: $1" >&2
  exit 1
}


check_version() {
  RELEASE=$1

  if echo "$1" | grep -Eq "latest"; then
    RELEASE=v0.1.0
  fi

  if ! wget -qS --spider "https://github.com/Djib-io/djib-relay-node/archive/refs/tags/$RELEASE.zip" > /dev/null 2>&1; then
    err "Unable to locate packages for $1!"
  fi
}


check_root() {
  if [ $EUID != 0 ]; then 
    err "You must run this command as root."; 
  fi
}


need_x64() {
  UNAME=`uname -m`
  if [ "$UNAME" != "x86_64" ]; then
    err "You must run this command on a 64-bit server."; 
  fi
}


need_pkg() {
  check_root

  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do 
    echo "Sleeping for 1 second because of dpkg lock"; sleep 1; 
  done

  if [ ! "$SOURCES_FETCHED" = true ]; then
    apt-get update
    SOURCES_FETCHED=true
  fi

  if ! dpkg -s ${@:1} >/dev/null 2>&1; then
    LC_CTYPE=C.UTF-8 apt-get install -yq ${@:1}
  fi

  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do 
    echo "Sleeping for 1 second because of dpkg lock"; sleep 1;
  done
}


check_ubuntu(){
  BASE=1799
  UBUNTU=$(lsb_release -d | awk '{print $2}' | grep "Ubuntu")
  if [ "$UBUNTU" != "Ubuntu" ]; then
     err "You must run this command on Ubuntu server.";
  fi
  RELEASE=$(lsb_release -r | sed 's/[^0-9]*//g')
  if (( RELEASE < BASE )); then
     err "You must run this command on Ubuntu 18.04<= server.";
  fi
}


check_mem() {
  if awk '$1~/MemTotal/ {exit !($2<3940000)}' /proc/meminfo; then
    echo "Your server needs to have (at least) 4G of memory."
    if [ "$SKIP_MIN_SERVER_REQUIREMENTS_CHECK" != true ]; then
      exit 1
    fi
  fi
}


check_cpus() {
  if [ "$(nproc --all)" -lt 2 ]; then
    echo "Your server needs to have (at least) 2 CPUs (4 recommended for production)."
    if [ "$SKIP_MIN_SERVER_REQUIREMENTS_CHECK" != true ]; then
      exit 1
    fi
  fi
}


# NOT RELEASED
install_docker() {
  need_pkg apt-transport-https ca-certificates curl gnupg-agent software-properties-common openssl

  # Install Docker
  if ! apt-key list | grep -q Docker; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  fi

  if ! dpkg -l | grep -q docker-ce; then
    add-apt-repository \
     "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) \
     stable"

    apt-get update
    need_pkg docker-ce docker-ce-cli containerd.io
  fi

  if ! which docker; then 
    err "Docker did not install"; 
  fi

  # Remove Docker Compose
  if dpkg -l | grep -q docker-compose; then
    apt-get purge -y docker-compose
  fi
}


install_nginx() {
  need_pkg apt-transport-https ca-certificates curl gnupg-agent software-properties-common openssl nginx
  systemctl enable nginx
  systemctl start nginx
}


wait_443() {
  echo "Waiting for port 443 to clear "
  # ss fields 4 and 6 are Local Address and State
  while ss -ant | awk '{print $4, $6}' | grep TIME_WAIT | grep -q ":443"; do sleep 1; echo -n '.'; done
  echo
}


get_IP() {
  if [ -n "$IP" ]; then return 0; fi

  # Determine local IP
  if [ -e "/sys/class/net/venet0:0" ]; then
    # IP detection for OpenVZ environment
    _dev="venet0:0"
  else
    _dev=$(awk '$2 == 00000000 { print $1 }' /proc/net/route | head -1)
  fi
  _ips=$(LANG=C ip -4 -br address show dev "$_dev" | awk '{ $1=$2=""; print $0 }')
  _ips=${_ips/127.0.0.1\/8/}
  read -r IP _ <<< "$_ips"
  IP=${IP/\/*} # strip subnet provided by ip address
  if [ -z "$IP" ]; then
    read -r IP _ <<< "$(hostname -I)"
  fi


  # Determine external IP 
  if [ -r /sys/devices/virtual/dmi/id/product_uuid ] && [ "$(head -c 3 /sys/devices/virtual/dmi/id/product_uuid)" == "EC2" ]; then
    # EC2
    local external_ip=$(wget -qO- http://169.254.169.254/latest/meta-data/public-ipv4)
  elif [ -f /var/lib/dhcp/dhclient.eth0.leases ] && grep -q unknown-245 /var/lib/dhcp/dhclient.eth0.leases; then
    # Azure
    local external_ip=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2017-08-01&format=text")
  elif [ -f /run/scw-metadata.cache ]; then
    # Scaleway
    local external_ip=$(grep "PUBLIC_IP_ADDRESS" /run/scw-metadata.cache | cut -d '=' -f 2)
  elif which dmidecode > /dev/null && dmidecode -s bios-vendor | grep -q Google; then
    # Google Compute Cloud
    local external_ip=$(wget -O - -q "http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" --header 'Metadata-Flavor: Google')
  fi

  # Check if the external IP reaches the internal IP
  if [ -n "$external_ip" ] && [ "$IP" != "$external_ip" ]; then
    if which nginx; then
      systemctl stop nginx
    fi

    need_pkg netcat-openbsd

    wait_443

    nc -l -p 443 > /dev/null 2>&1 &
    nc_PID=$!
    sleep 1
    
     # Check if we can reach the server through it's external IP address
     if nc -zvw3 "$external_ip" 443  > /dev/null 2>&1; then
       INTERNAL_IP=$IP
       IP=$external_ip
       echo 
       echo "  Detected this server has an internal/external IP address."
       echo 
       echo "      INTERNAL_IP: $INTERNAL_IP"
       echo "    (external) IP: $IP"
       echo 
     fi

    kill $nc_PID  > /dev/null 2>&1;

    if which nginx; then
      systemctl start nginx
    fi
  fi

  if [ -z "$IP" ]; then err "Unable to determine local IP address."; fi
}


check_apache2() {
  if dpkg -l | grep -q apache2-bin; then 
    err "You must uninstall the Apache2 server first"
  fi
}


# Check if running externally with internal/external IP addresses
check_nat() {
  if [ -n "$INTERNAL_IP" ]; then
    ip addr add "$IP" dev lo

    # If dummy NIC is not in dummy-nic.service (or the file does not exist), update/create it
    if ! grep -q "$IP" /lib/systemd/system/dummy-nic.service > /dev/null 2>&1; then
      if [ -f /lib/systemd/system/dummy-nic.service ]; then 
        DAEMON_RELOAD=true; 
      fi

      sed -i "s~DJIBIPHOST~$IP~g" ./services/dummy-nic.service
      cp ./services/dummy-nic.service /lib/systemd/system/dummy-nic.service

      if [ "$DAEMON_RELOAD" == "true" ]; then
        systemctl daemon-reload
        systemctl restart dummy-nic
      else
        systemctl enable dummy-nic
        systemctl start dummy-nic
      fi
    fi
  fi
}


install_node_18() {
  if ! grep -q 18 /etc/apt/sources.list.d/nodesource.list ; then # Node 18 might be installed
    sudo apt-get purge nodejs
    sudo rm -r /etc/apt/sources.list.d/nodesource.list
  fi
  
  if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
    curl -sL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  fi
  
  if ! apt-cache madison nodejs | grep -q node_18; then
    err "Did not detect nodejs 18.x candidate for installation"
  fi

  apt-get update

  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" dist-upgrade

  need_pkg nodejs
}


set_repos() {
  need_pkg software-properties-common  # needed for add-apt-repository
  add-apt-repository universe -y
  add-apt-repository ppa:deadsnakes/ppa -y
  need_pkg build-essential unzip apt-transport-https curl gpg-agent dirmngr git ca-certificates python3.10 python3-pip python3-venv
}

# setup_ufw() {
# }


install_relay() {
  wget -O /$DJIB_ROOT/tmp/relay.zip https://github.com/Djib-io/djib-relay-node/archive/refs/tags/$RELEASE.zip
  unzip $DJIB_ROOT/tmp/relay.zip -d "$DJIB_ROOT/"
  mv $DJIB_ROOT/djib-relay-node-$(echo $RELEASE | sed 's/v*//g') $DJIB_ROOT/relay
  pip3.10 install -r $DJIB_ROOT/relay/requirements.txt
  FLASK_SECRET=$(echo $RANDOM | md5sum | head -c 30; echo;)$(echo $RANDOM | md5sum | head -c 30; echo;)
  cp $DJIB_ROOT/relay/dev.env  $DJIB_ROOT/relay/.env
  cp ./services/djib-relay.service /lib/systemd/system/djib-relay.service
  sed -i "s~TempSecretForFLASK~$FLASK_SECRET~g" $DJIB_ROOT/relay/.env
  sed -i "s~FLASK_PORT=80~FLASK_PORT=8081~g" $DJIB_ROOT/relay/.env
  systemctl daemon-reload
  systemctl enable djib-relay
  systemctl start djib-relay
}


install_setup_api() {
  wget -O /$DJIB_ROOT/tmp/api.zip https://github.com/Djib-io/djib-node-setup-api/archive/refs/tags/$RELEASE.zip
  unzip $DJIB_ROOT/tmp/api.zip -d "$DJIB_ROOT/"
  mv $DJIB_ROOT/djib-node-setup-api-$(echo $RELEASE | sed 's/v*//g') $DJIB_ROOT/api
  pip3.10 install -r $DJIB_ROOT/api/requirements.txt
  FLASK_SECRET=$(echo $RANDOM | md5sum | head -c 30; echo;)$(echo $RANDOM | md5sum | head -c 30; echo;)
  cp $DJIB_ROOT/api/dev.env  $DJIB_ROOT/api/.env
  sed -i "s~TempSecretForFLASK~$FLASK_SECRET~g" $DJIB_ROOT/api/.env
  sed -i "s~FLASK_PORT=80~FLASK_PORT=8080~g" $DJIB_ROOT/api/.env
  cp ./services/djib-setup-api.service /lib/systemd/system/djib-setup-api.service
  systemctl daemon-reload
  systemctl enable djib-setup-api
  systemctl start djib-setup-api
}


install_setup_ui() {
  wget -O /$DJIB_ROOT/tmp/ui.zip https://github.com/Djib-io/djib-node-setup-ui/archive/refs/tags/$RELEASE.zip
  unzip $DJIB_ROOT/tmp/ui.zip -d "$DJIB_ROOT/"
  mv $DJIB_ROOT/djib-node-setup-ui-$(echo $RELEASE | sed 's/v*//g') $DJIB_ROOT/ui
  npm install --prefix $DJIB_ROOT/ui
  npm run build --prefix $DJIB_ROOT/ui
  cp -r $DJIB_ROOT/ui/build /usr/share/nginx/
  rm -rf /usr/share/nginx/html
  mv /usr/share/nginx/build /usr/share/nginx/html
}


need_ppa() {
  need_pkg software-properties-common 
  if [ ! -f "/etc/apt/sources.list.d/$1" ]; then
    LC_CTYPE=C.UTF-8 add-apt-repository -y "$2"
  fi
  if ! apt-key list "$3" | grep -q -E "1024|4096"; then  # Let's try it a second time
    LC_CTYPE=C.UTF-8 add-apt-repository "$2" -y
    if ! apt-key list "$3" | grep -q -E "1024|4096"; then
      err "Unable to setup PPA for $2"
    fi
  fi
}


install_ssl() {
  sudo apt-get install python3-pkg-resources -y
  sudo apt-get install --reinstall python3-pkg-resources -y
  sudo apt install certbot python3-certbot-nginx -y
  certbot --help
  sudo apt-get install --reinstall python3-pkg-resources -y
  url=$(curl --location --request POST 'https://nodes.djib.io/api/rpc' --header 'Content-Type: application/json' --data-raw '{"jsonrpc": "2.0","id": 1,"method": "registerDn","params": []}')
  adminurl=$(echo $url | sed 's/{"jsonrpc": "2.0", "result": "*//g' | sed 's/", "id": 1}*//g' | sed 's/https:\/\/*//g' )
}


main() {
  export DEBIAN_FRONTEND=noninteractive
  DJIB_ROOT="/var/djib"
  SOURCES_FETCHED=false
  CR_TMPFILE=$(mktemp /tmp/carriage-return.XXXXXX)
  echo "\n" > $CR_TMPFILE
  VERSION=v0.1.0

  need_x64

  while builtin getopts "hv:es:wj" opt "${@}"; do

    case $opt in
      h)
        usage
        exit 0
        ;;

      v)
        VERSION=$OPTARG
        ;;

      w)
        SSH_PORT=$(grep Port /etc/ssh/ssh_config | grep -v \# | sed 's/[^0-9]*//g')
        if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
          err "ssh service not listening to standard port 22; unable to install default UFW firewall rules."
        fi
        UFW=true
        ;;

      j)
        SKIP_MIN_SERVER_REQUIREMENTS_CHECK=true
        ;;

      i)
        SKIP_APACHE_INSTALLED_CHECK=true
        ;;

      :)
        err "Missing option argument for -$OPTARG"
        exit 1
        ;;

      \?)
        err "Invalid option: -$OPTARG" >&2
        usage
        ;;
    esac
  done

  check_root

  check_ubuntu

  check_mem

  check_cpus


  check_version "$VERSION"


  if [ "$SKIP_APACHE_INSTALLED_CHECK" != true ]; then
    check_apache2
  fi

  env
  
  install_nginx


  get_IP


  set_repos


  install_node_18  

  
  check_nat

  if [ -n "$LINK_PATH" ]; then
    ln -s "$LINK_PATH" $DJIB_ROOT
  fi

  mkdir -p $DJIB_ROOT/tmp

  curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10
  
  pip3.10 install --upgrade setuptools
 
  install_relay

  install_setup_api

  install_setup_ui

  install_ssl

  cp ./nginx/djib.conf /etc/nginx/conf.d/djib.conf
  
  sed -i "s~DJIBIPHOST~$IP $adminurl~g" /etc/nginx/conf.d/djib.conf

  systemctl restart nginx

  apt-get auto-remove -y

  systemctl restart systemd-journald

  if [ -n "$UFW" ]; then
    setup_ufw 
  fi
}


main "$@" || exit 1
