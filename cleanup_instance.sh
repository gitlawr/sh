#!/bin/bash

INTERVAL=2
while true; do
    ids=$(curl -s localhost/v2/model-instances | jq -r '.items[].id')
    if [ -n "$ids" ]; then
        for id in $ids; do
            curl -s -X DELETE "localhost/v2/model-instances/$id" > /dev/null
        done
    fi

    echo "Completed. Wait for $INTERVAL seconds..."
    sleep $INTERVAL
done
