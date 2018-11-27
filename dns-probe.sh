#!/bin/bash
var=1
while true ; do
  echo "trying #$var"
  res=$( { curl -o /dev/null -s -w %{time_namelookup}\\n  http://www.rancher.com; } 2>&1 )
  var=$((var+1))
  if [[ $res =~ ^[1-9] ]]; then
    now=$(date +"%T")
    echo "#$var slow: $res $now"
  fi
done
