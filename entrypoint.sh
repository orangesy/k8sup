#!/bin/bash
set -e

function etcd_creator(){
  local IPADDR="$1"
  local ETCD_NAME="node-$(uuidgen -r | cut -c1-6)"

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --restart=always \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:2379,http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:2380  \
      --listen-peer-urls http://0.0.0.0:2380 \
      --initial-cluster-token etcd-cluster-1 \
      --initial-cluster "${ETCD_NAME}=http://${IPADDR}:2380" \
      --initial-cluster-state new \
      --data-dir /var/lib/etcd
}

function etcd_follower(){
  local IPADDR="$1"
  local ETCD_MEMBER="$(echo "$2" | cut -d ':' -f 1)"
  local ETCD_NAME="node-$(uuidgen -r | cut -c1-6)"
  local PORT="2379"
  local PEER_PORT="2380"
  local PROXY="off"
  local ETCD2_MAX_MEMBER_SIZE="5"

  docker pull "${ENV_ETCD_IMAGE}" 1>&2

  # Check if cluster is full
  local ETCD_EXISTED_MEMBER_SIZE="$(curl -sf --retry 10 \
    http://${ETCD_MEMBER}:${PORT}/v2/members | jq '.[] | length')"
  if [ "${ETCD_EXISTED_MEMBER_SIZE}" -lt "${ETCD2_MAX_MEMBER_SIZE}" ]; then
    # If cluster is not full, Disable proxy
    local PROXY="off"
  else
    # If cluster is full, use proxy mode
    local PROXY="on"
  fi

  # If cluster is not full, Use locker (etcd atomic CAS) to get a privilege for joining etcd cluster
  local LOCKER_ETCD_KEY="vsdx/locker-etcd-member-add"
  until [[ "${PROXY}" == "on" ]] || curl -sf \
    "http://${ETCD_MEMBER}:${PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevExist=false" \
    -XPUT -d value="${IPADDR}" 1>&2; do
      echo "Another node is joining etcd cluster, Waiting for it done..." 1>&2
      sleep 1

      # Check if cluster is full
      local ETCD_EXISTED_MEMBER_SIZE="$(curl -sf --retry 10 \
        http://${ETCD_MEMBER}:${PORT}/v2/members | jq '.[] | length')"
      if [ "${ETCD_EXISTED_MEMBER_SIZE}" -lt "${ETCD2_MAX_MEMBER_SIZE}" ]; then
        # If cluster is not full, Disable proxy
        local PROXY="off"
      else
        # If cluster is full, use proxy mode
        local PROXY="on"
      fi
  done
  if [[ "${PROXY}" == "off" ]]; then
    # Run etcd member add
    curl -s "http://${ETCD_MEMBER}:${PORT}/v2/members" -XPOST \
      -H "Content-Type: application/json" -d "{\"peerURLs\":[\"http://${IPADDR}:${PEER_PORT}\"]}" 1>&2
  fi

  # Update Endpoints to etcd2 parameters
  local MEMBERS="$(curl -s http://${ETCD_MEMBER}:${PORT}/v2/members)"
  local SIZE="$(echo "${MEMBERS}" | jq '.[] | length')"
  local PEER_IDX=0
  local ENDPOINTS="${ETCD_NAME}=http://${IPADDR}:${PEER_PORT}"
  for PEER_IDX in $(seq 0 "$((${SIZE}-1))"); do
    local PEER_NAME="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].name")"
    local PEER_URL="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].peerURLs[] | select(contains("\"${PEER_PORT}\""))")"
    if [ -n "${PEER_URL}" ] && [ "${PEER_URL}" != "http://${IPADDR}:${PEER_PORT}" ]; then
      ENDPOINTS="${ENDPOINTS},${PEER_NAME}=${PEER_URL}"
    fi
  done

  docker run \
    -d \
    --net=host \
    --name=k8sup-etcd \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
    --name "${ETCD_NAME}" \
    --advertise-client-urls http://${IPADDR}:2379,http://${IPADDR}:4001 \
    --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
    --initial-advertise-peer-urls http://${IPADDR}:2380 \
    --listen-peer-urls http://0.0.0.0:2380 \
    --initial-cluster-token etcd-cluster-1 \
    --initial-cluster "${ENDPOINTS}" \
    --initial-cluster-state existing \
    --data-dir /var/lib/etcd \
    --proxy "${PROXY}"


  if [ "${PROXY}" == "off" ]; then
    # Unlock and release the privilege for joining etcd cluster
    until curl -sf "http://${ETCD_MEMBER}:${PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevValue=${IPADDR}" -XDELETE 1>&2; do
        sleep 1
    done
  fi
}

function flanneld(){
  local IPADDR="$1"
  local ETCD_CID="$2"

  echo "Setting flannel parameters to etcd"
  local KERNEL_SHORT_VERSION="$(uname -r | cut -d '.' -f 1-2)"
  local VXLAN="$(echo "${KERNEL_SHORT_VERSION} >= 3.9" | bc)"
  if [ "${VXLAN}" -eq 1 ] && [ -n "$(lsmod | grep vxlan &> /dev/null)" ]; then
    docker exec -it \
      "${ETCD_CID}" \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:2379 \
      set /coreos.com/network/config "{ \"Network\": \"10.1.0.0/16\", \"Backend\": { \"Type\": \"vxlan\"}}"
  else
    docker exec -it \
      "${ETCD_CID}" \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:2379 \
      set /coreos.com/network/config "{ \"Network\": \"10.1.0.0/16\" }"
  fi

  docker run \
    -d \
    --name k8sup-flannel \
    --net=host \
    --privileged \
    --restart=always \
    -v /dev/net:/dev/net \
    -v /run/flannel:/run/flannel \
    "${ENV_FLANNELD_IMAGE}" \
    /opt/bin/flanneld \
      --etcd-endpoints=http://${IPADDR}:4001 \
      --iface=${IPADDR}
}

function main(){

  export ENV_ETCD_VERSION="3.0.4"
  export ENV_FLANNELD_VERSION="0.5.5"
#  export ENV_K8S_VERSION="1.3.4"
  export ENV_ETCD_IMAGE="quay.io/coreos/etcd:v${ENV_ETCD_VERSION}"
  export ENV_FLANNELD_IMAGE="quay.io/coreos/flannel:${ENV_FLANNELD_VERSION}"
#  export ENV_HYPERKUBE_IMAGE="gcr.io/google_containers/hyperkube-amd64:v${ENV_K8S_VERSION}"

  local IPADDR="$1"
  if [[ -z "${IPADDR}" ]]; then
    echo "Need IP address as argument, exiting..." 1>&2
    exit 1
  fi

  echo "Copy cni plugins"
  cp -rf bin /opt/cni
  mkdir -p /etc/cni/net.d/
  cp -f /go/cni-conf/10-containernet.conf /etc/cni/net.d/
  cp -f /go/cni-conf/99-loopback.conf /etc/cni/net.d/
  mkdir -p /var/lib/cni/networks/mynet; echo "" > /var/lib/cni/networks/mynet/last_reserved_ip

  sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-flannel' >/dev/null 2>&1 || true

  echo "Running etcd"
  local EXISTED_ETCD_MEMBER="$2"
  if [[ -z "${EXISTED_ETCD_MEMBER}" ]]; then
    local ETCD_CID=$(etcd_creator "${IPADDR}")
  else
    local ETCD_CID=$(etcd_follower "${IPADDR}" "${EXISTED_ETCD_MEMBER}")
  fi

  until curl -s 127.0.0.1:2379/v2/keys 1>/dev/null 2>&1; do
    echo "Waiting for etcd ready..."
    sleep 1
  done
  echo "Running flanneld"
  flanneld "${IPADDR}" "${ETCD_CID}"

#  echo "Running Kubernetes"
  /go/kube-up "${IPADDR}"

}

main "$@"
