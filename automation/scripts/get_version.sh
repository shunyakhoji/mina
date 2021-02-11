#!/bin/bash

namespace=$1
pod=$(kubectl get pods -n $namespace | grep 'whale' | sed -n '2 p' | awk '{print $1;}')
#echo $pod

kubectl -n $namespace exec -c mina -i $pod -- apt list mina-testnet-postake-medium-curves 2>/dev/null | sed -n '2 p' | sed 's/.*from: //' | sed 's/]//'

