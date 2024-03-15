################ SET RUN TYPE DEUBGING ################
# RUN_TYPE="installation" #debugging                  #
# RUN_TYPE="nightly" #debugging                       #
#######################################################

max_attempts=60
sleep_interval=5

check_telemetry_enabled() {
  # openshift_pullsecret_exists=$(oc get secret pull-secret -n openshift-config --ignore-not-found=true)
  # if [[ -n $openshift_pullsecret_exists ]]; then
  #   cloud_dot_openshift_cluster=$(oc get secret pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq -r '.auths."cloud.openshift.com"')
  #   if [[ -n $cloud_dot_openshift_cluster ]]; then
  #     echo "This cluster has \`cloud.openshift.com\` pullsecret credentials, and is thus deemed a CI cluster. Exiting, analytics not meant for CI clusters"
  #     exit 1
  #   fi
  # fi
  cluster_monitoring_config_exists=$(oc get configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found=true)
  if [[ -n $cluster_monitoring_config_exists ]]; then
    cluster_monitoring_configs=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o json | jq '.data."config.yaml"' | cut -d "\"" -f 2)
    echo $cluster_monitoring_configs > ./cluster-monitoring-config.yaml
  fi
  openshift_console_operator=$(oc get console.operator.openshift.io cluster -o json --ignore-not-found=true)
  if [[ -n $openshift_console_operator ]]; then
    disabled_annotation_exists=$(oc get console.operator.openshift.io cluster -o json | jq -r '.metadata.annotations."telemetry.console.openshift.io/DISABLED"')
    if [[ $disabled_annotation_exists == "true" ]]; then
      echo "Console Operator has annotation for disabling telemetry. Cancelling job."
      exit 1
    fi
  fi 
  return 0
}

check_thanos_querier_status() {
    local attempts=0

    while [[ $attempts -lt $max_attempts ]]; do
        route_exists=$(oc get route thanos-querier -n openshift-monitoring --ignore-not-found=true)
        if [[ -n $route_exists ]]; then
            echo "route \"thanos-querier\" is up and running in namespace "openshift-monitoring"."
            return 0
        else
            echo "Thanos Querier route is not up yet. Retrying in $sleep_interval seconds..."
        fi
        sleep $sleep_interval
        attempts=$((attempts + 1))
    done

    echo "Timed out. Thanos Querier route did not spin up in the \"openshift-monitoring\" namespace."
    return 1
}

check_pull_secret() {
    local attempts=0

    while [[ $attempts -lt $max_attempts ]]; do
        pull_secret_exists=$(oc get secret pull-secret -n sigstore-monitoring --ignore-not-found=true)
        if [[ -n $pull_secret_exists ]]; then
            echo "secret \"pull-secret\" in namespace \"sigstore-monitoring\" exists, proceeding."
            return 0
        else
            echo "Waiting for secret \"pull-secret\" in namespace \"sigstore-monitoring\" to exist..."
            sleep $sleep_interval
            attempts=$((attempts + 1))
        fi
    done

    echo "Timed out. Cannot find secret \"pull-secret\" in namespace \"sigstore-monitoring\"."
    echo "Please download the pull-secret from \`https://console.redhat.com/application-services/trusted-content/artifact-signer\`
    and create a secret from it: \`oc create secret generic pull-secret -n sigstore-monitoring --from-file=\$HOME/Downloads/pull-secret.json\`."
    return 1
}

telemetry_disabled_message=$(check_telemetry_enabled)
if [[ $? == 1 ]]; then
  echo $telemetry_disabled_message
  exit 1
fi
exit 0
check_pull_secret
check_thanos_querier_status

pull_secret_exists=$(oc get secret  pull-secret -n sigstore-monitoring --ignore-not-found=true)

if [[ -z $pull_secret_exists ]]; then
    echo "Error, Secret \`pull-secret\` does not exist in nampesace \`sigstore-monitoring\`.
    Please download the pull-secret from \`https://console.redhat.com/application-services/trusted-content/artifact-signer\`
    and create a secret from it: \`oc create secret generic pull-secret -n sigstore-monitoring --from-file=\$HOME/Downloads/pull-secret.json\`. "
    exit 0
fi

secret_data=$(oc get secret pull-secret -n sigstore-monitoring -o "jsonpath={.data.pull-secret\.json}")
registry_auth=$(echo $secret_data | base64 -d | jq .auths."\"registry.redhat.io\"".auth | cut -d "\"" -f 2 | base64 -d)

declare registry_org_id_index
declare registry_user_id_index
base64_indexes=()

for ((i=0; i<${#registry_auth}; i++)); do
  char="${registry_auth:$i:1}"
  if [[ $char == "|" ]]; then
    registry_org_id_index=$i
  elif [[ $char == ":" ]]; then
    registry_user_id_index=$i
  elif [[ $char == "." ]]; then
    base64_indexes+=("$i")
  fi
done

# registryregistry_org_id=${registry_auth:0:$registry_org_id_index}
# registry_user_id=${registry_auth:$registry_org_id_index+1:$registry_user_id_index-($registry_org_id_index+1)}
org_id=$(echo $secret_data | base64 -d | jq ".orgId" | cut -d "\"" -f 2 )
user_id=$(echo $secret_data | base64 -d  | jq ".userId" | cut -d "\"" -f 2 )
alg_id=$(echo ${registry_auth:$registry_user_id_index+1:(${base64_indexes[0]}-($registry_user_id_index+1))} | base64 -d | jq .alg | cut -d "\"" -f 2 )
sub_id=$(echo ${registry_auth:(${base64_indexes[0]}+1):(${base64_indexes[1]}-${base64_indexes[0]}-1)} | base64 -d | jq .sub |  cut -d "\"" -f 2)

PROM_TOKEN_SECRET_NAME=$(oc get secret -n openshift-user-workload-monitoring | grep  prometheus-user-workload-token | head -n 1 | awk '{print $1 }')
PROM_TOKEN_DATA=$(echo $(oc get secret $PROM_TOKEN_SECRET_NAME -n openshift-user-workload-monitoring -o json | jq -r '.data.token') | base64 -d)
THANOS_QUERIER_HOST=$(oc get route thanos-querier -n openshift-monitoring -o json | jq -r '.spec.host')

echo "org_id: $org_id" > /opt/app-root/src/tmp
echo "user_id: $user_id" >> /opt/app-root/src/tmp
# echo "registry_org_id: $registry_org_id" > /opt/app-root/src/tmp
# echo "registry_user_id: $registry_user_id" >> /opt/app-root/src/tmp
echo "alg_id: $alg_id" >> /opt/app-root/src/tmp
echo "sub_id: $sub_id" >> /opt/app-root/src/tmp

if [[ $RUN_TYPE == "nightly" ]]; then
  fulcio_new_certs=$(curl -X GET -kG "https://$THANOS_QUERIER_HOST/api/v1/query?" --data-urlencode "query=fulcio_new_certs" -H "Authorization: Bearer $PROM_TOKEN_DATA" | jq '.data.result[] | .value[1]')

  rekor_new_entries_query_data=$(curl -X GET -kG "https://$THANOS_QUERIER_HOST/api/v1/query?" --data-urlencode "query=rekor_new_entries" -H "Authorization: Bearer $PROM_TOKEN_DATA" | jq '.data.result[]' )
  declare rekor_new_entries
  if [[ -z $rekor_new_entries_query_data ]]; then
    rekor_new_entries="0"
  else 
    rekor_new_entries=$(curl -X GET -kG "https://$THANOS_QUERIER_HOST/api/v1/query?" --data-urlencode "query=rekor_new_entries" -H "Authorization: Bearer $PROM_TOKEN_DATA" | jq '.data.result[] | .value[1]')
  fi

  declare rekor_qps_by_api
  rekor_qps_by_api_query_data=$(curl -X GET -kG "https://$THANOS_QUERIER_HOST/api/v1/query?" --data-urlencode "query=rekor_qps_by_api" -H "Authorization: Bearer $PROM_TOKEN_DATA" | jq '.data.result[]' )
  if [[ -z $rekor_qps_by_api_query_data ]]; then
    rekor_qps_by_api=""
  else 
    rekor_qps_by_api=$(curl -X GET -kG "https://$THANOS_QUERIER_HOST/api/v1/query?" --data-urlencode "query=rekor_qps_by_api" -H "Authorization: Bearer $PROM_TOKEN_DATA" | \
    jq -r '.data.result[] | "method:" + .metric.method + ",status_code:" + .metric.code + ",path:" + .metric.path + ",value:" + .value[1] + "|"')
  fi
  
  echo "fulcio_new_certs: $fulcio_new_certs" >> /opt/app-root/src/tmp
  echo "rekor_new_entries: $rekor_new_entries" >> /opt/app-root/src/tmp
  echo "rekor_qps_by_api: " $rekor_qps_by_api >> /opt/app-root/src/tmp
fi

if [[ $RUN_TYPE == "nightly" ]]; then
  python3 /opt/app-root/src/main-nightly.py
elif [[ $RUN_TYPE == "installation" ]]; then
  python3 /opt/app-root/src/main-installation.py
else 
  echo "error \$RUN_TYPE not set.
    options: \"nightly\", \"installation\""
  exit 1
fi