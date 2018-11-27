#!/bin/sh
# `getent ahosts` uses glibc getaddrinfo() under the hood allowing us
# to replicate DNS query behaviour of typical application workloads.
# Especially with regards to parallel querying behaviour for both A/AAAA,
# which dig or nslookup both do *not* have.

# tcpdump -n -i eth0 udp port 53 -w dns-clusterip.pcap &
# PID=$!
# echo $PID

while true; do
  res=`time getent ahosts docs.rancher.com 2>&1`
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "$res"
    break
  fi
  # Limit to 100qps to not delute test results
  # by hitting rate limits of upstream DNS.
  # sleep 0.01
done
# kill $PID
