#!/bin/bash

# assure zookeeper services have been created
while IFS=',' read -ra ZK; do
  for i in "${ZK[@]}"; do 
    read ZK_HOST ZK_PORT <<< $(echo $i | sed 's/\(.*\):\([0-9]*\)/\1 \2/')
    if [ ${ZK_HOST} == "" ] || [ ${ZK_PORT} == "" ]; then
      echo "zookeeper service must be created before starting pods..."
      sleep 30 # To postpone pod restart
      exit 1
    fi
  done
done <<< "$ZOOKEEPER_CONNECT"

#Find the broker id 
# => try to leverage etcd's atomically creating in-order keys as broker id if new created pod
# => use /kafka_data/myid for existing pod

if [ -r /kafka_data/data/myid ]; then
  BROKER_ID=`(cat /kafka_data/data/myid)`
  echo "use existing broker id: ${BROKER_ID}"
else
  # curl -m: max operation timeout; -Ss: hide progress meter but show error; --stderr -: redirect all writes to stdout
  KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  KUBE_ENDPOINT=$(curl -m 2 -Ss --stderr - -k https://${KUBERNETES_SERVICE_HOST}/api/v1/namespaces/default/endpoints/kubernetes -H "Authorization: Bearer ${KUBE_TOKEN}")
  if [ $(echo ${KUBE_ENDPOINT} | jq -r '.subsets[0].addresses[0].ip != null') != true ]; then
    echo "kubernetes service's endpoint is not ready..."
    sleep 30 # To postpone pod restart
    exit 1
  fi
  ETCD2_ENDPOINT="$(echo ${KUBE_ENDPOINT} | jq -r '.subsets[0].addresses[0].ip'):2379"
  echo "etcd2 endpoint: ${ETCD2_ENDPOINT}"

  MAX_JAVA_INT=2147483647
  INDEX=`(curl -L -Ss --stderr - http://${ETCD2_ENDPOINT}/v2/keys/${POD_NAMESPACE}/kafka -XPOST -d ttl=5 | sed 's/.*createdIndex":\([0-9]*\).*/\1/')`
  BROKER_ID=`(expr ${INDEX} % ${MAX_JAVA_INT})`
  if [[ ${BROKER_ID} == "" ]]; then
    echo "etcd service is not ready..."
    sleep 30 # To postpone pod restart
    exit 1  
  fi
  echo ${BROKER_ID} > /kafka_data/data/myid
  echo "create a new broker id: ${BROKER_ID}"
fi

echo "zookeeper.connect=${ZOOKEEPER_CONNECT}"
echo ""

#Use "#" as delimiter because ZOOKEEPER_CONNECT may contain generally used delimiter "/"
sed -i "s#%%BROKER_ID%%#`echo ${BROKER_ID}`#g;s#%%ZOOKEEPER_CONNECT%%#`echo ${ZOOKEEPER_CONNECT}`#g;s#%%IP%%#$(hostname -i)#g" /opt/kafka/config/server.properties

#export CLASSPATH=$CLASSPATH:/opt/kafka/lib/slf4j-log4j12.jar
#export JMX_PORT=7203

cat /opt/kafka/config/server.properties

echo ""
echo "Starting kafka"
exec /opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
